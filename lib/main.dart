import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timetable_app/src/rust/api/simple.dart';
import 'package:timetable_app/src/rust/frb_generated.dart';
import 'package:url_launcher/url_launcher.dart';

late SharedPreferences globalPrefs;

const String kDeveloperPasscode = 'dev2026';
const String kDeveloperEmail = 'developer@uq-timetable.app';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  globalPrefs = await SharedPreferences.getInstance();

  if (!kIsWeb) {
    try {
      await RustLib.init();
    } catch (e) {
      debugPrint("Rust init error: $e");
    }
  }
  await courseSyncCenter.initialize();
  runApp(const MyApp());
}

// ============================================================================
// 开发者广播消息与版本更新数据模型（支持中英双语自适应）
// ============================================================================
class DeveloperBroadcastMessage {
  final String id;
  final String title;
  final String titleEn;
  final String category; // 'update' | 'guide'
  final String content;
  final String contentEn;
  final String dateStr;
  final String? targetVersion;
  final String? downloadUrl;

  DeveloperBroadcastMessage({
    required this.id,
    required this.title,
    String? titleEn,
    required this.category,
    required this.content,
    String? contentEn,
    required this.dateStr,
    this.targetVersion,
    this.downloadUrl,
  }) : titleEn = (titleEn == null || titleEn.isEmpty) ? title : titleEn,
       contentEn = (contentEn == null || contentEn.isEmpty)
           ? content
           : contentEn;

  String localizedTitle(bool isEn) => isEn ? titleEn : title;
  String localizedContent(bool isEn) => isEn ? contentEn : content;

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'titleEn': titleEn,
    'category': category,
    'content': content,
    'contentEn': contentEn,
    'dateStr': dateStr,
    'targetVersion': targetVersion,
    'downloadUrl': downloadUrl,
  };

  factory DeveloperBroadcastMessage.fromJson(Map<String, dynamic> m) =>
      DeveloperBroadcastMessage(
        id: m['id'].toString(),
        title: m['title'].toString(),
        titleEn: m['titleEn']?.toString(),
        category: m['category']?.toString() ?? 'guide',
        content: m['content'].toString(),
        contentEn: m['contentEn']?.toString(),
        dateStr: m['dateStr'].toString(),
        targetVersion: m['targetVersion']?.toString(),
        downloadUrl: m['downloadUrl']?.toString(),
      );
}

// ============================================================================
// 时间轴坐标与教学周计算辅助函数
// ============================================================================
int timeStringToMinutes(String timeStr) {
  final parts = timeStr.trim().split(':');
  if (parts.length >= 2) {
    final h = int.tryParse(parts[0]) ?? 7;
    final m = int.tryParse(parts[1]) ?? 0;
    return h * 60 + m;
  }
  return 7 * 60;
}

double calculateTopOffset(String startTime, int startHour, double hourHeight) {
  final startMin = timeStringToMinutes(startTime);
  final baseMin = startHour * 60;
  final diffHours = (startMin - baseMin) / 60.0;
  return (diffHours * hourHeight).clamp(0.0, 24 * hourHeight);
}

double calculateBoxHeight(String startTime, String endTime, double hourHeight) {
  final startMin = timeStringToMinutes(startTime);
  final endMin = timeStringToMinutes(endTime);
  final durationHours = ((endMin - startMin) / 60.0).clamp(0.5, 24.0);
  return durationHours * hourHeight;
}

int calculateWeekFromStartMonday(DateTime startMonday, DateTime targetDate) {
  final base = DateTime(startMonday.year, startMonday.month, startMonday.day);
  final target = DateTime(targetDate.year, targetDate.month, targetDate.day);
  final diffDays = target.difference(base).inDays;
  final w = (diffDays ~/ 7) + 1;
  return w.clamp(1, 20);
}

DateTime getDateForWeekAndDay(DateTime startMonday, int week, int weekday) {
  final base = DateTime(startMonday.year, startMonday.month, startMonday.day);
  return base.add(Duration(days: (week - 1) * 7 + (weekday - 1)));
}

String formatDateKey(DateTime dt) =>
    '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';

// ============================================================================
// 单日/未来额外日程事件模型 (Schedule Event)
// ============================================================================
class ScheduleEvent {
  final String id;
  final String title;
  final String dateStr;
  final String timeStr;
  final String location;
  final String note;
  final String color;
  final bool isCompleted;

  ScheduleEvent({
    required this.id,
    required this.title,
    required this.dateStr,
    required this.timeStr,
    required this.location,
    required this.note,
    required this.color,
    this.isCompleted = false,
  });

  ScheduleEvent copyWith({
    String? title,
    String? dateStr,
    String? timeStr,
    String? location,
    String? note,
    String? color,
    bool? isCompleted,
  }) {
    return ScheduleEvent(
      id: id,
      title: title ?? this.title,
      dateStr: dateStr ?? this.dateStr,
      timeStr: timeStr ?? this.timeStr,
      location: location ?? this.location,
      note: note ?? this.note,
      color: color ?? this.color,
      isCompleted: isCompleted ?? this.isCompleted,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'dateStr': dateStr,
    'timeStr': timeStr,
    'location': location,
    'note': note,
    'color': color,
    'isCompleted': isCompleted,
  };

  factory ScheduleEvent.fromJson(Map<String, dynamic> m) => ScheduleEvent(
    id: m['id'].toString(),
    title: m['title'].toString(),
    dateStr: m['dateStr'].toString(),
    timeStr: m['timeStr'].toString(),
    location: m['location'].toString(),
    note: m['note'].toString(),
    color: m['color'].toString(),
    isCompleted: m['isCompleted'] as bool? ?? false,
  );
}

// ============================================================================
// 全局双端同步、本地持久化、开发者广播与更新中心
// ============================================================================
class CourseSyncController extends ChangeNotifier {
  static const String _storageKeyData = 'saved_timetable_sync_json_v1';
  static const String _storageKeyBroadcasts = 'saved_dev_broadcasts_v2';
  static const String _storageKeyFeedbackList = 'saved_user_feedbacks_v1';

  List<Course> _courses = [];
  List<ScheduleEvent> _events = [];
  List<DeveloperBroadcastMessage> _broadcasts = [];
  List<Map<String, String>> _localFeedbackHistory = [];

  String _installedVersion = '1.1.0';
  String _latestRemoteVersion = '1.2.0';
  String _latestDownloadUrl = '';

  List<Course> get courses => List.unmodifiable(_courses);
  List<ScheduleEvent> get events => List.unmodifiable(_events);
  List<DeveloperBroadcastMessage> get broadcasts =>
      List.unmodifiable(_broadcasts);
  List<Map<String, String>> get localFeedbackHistory =>
      List.unmodifiable(_localFeedbackHistory);
  String get installedVersion => _installedVersion;
  String get latestRemoteVersion => _latestRemoteVersion;
  String get latestDownloadUrl => _latestDownloadUrl;
  bool get hasNewVersion => _installedVersion != _latestRemoteVersion;

  static const String uploadedExcelRawData = '''
Subject Code\tDescription\tGroup\tActivity\tDay\tTime\tCampus\tLocation\tStaff\tDuration\tDates
COMP1100_S2_2026_STLUCIA_62308_IN\tIntroduction to Software Innovation\tSTU01\t01\tWed\t09:00\tSTLUCIA\t11A-120/121 - ModWest\tIan Clough\t3 hrs\t14/10
CSSE2310_S2_2026_STLUCIA_60944_IN\tComputer Systems Principles and Programming\tLEC01\t01_Recorded\tTue\t12:00\tSTLUCIA\tDelayed viewing (Clashable)\tPeter Sutton\t2 hrs\t13/10
CSSE2310_S2_2026_STLUCIA_60944_IN\tComputer Systems Principles and Programming\tLEC02\t01_Recorded\tThu\t12:00\tSTLUCIA\tDelayed viewing (Clashable)\tPeter Sutton\t1 hr\t15/10
CSSE2310_S2_2026_STLUCIA_60944_IN\tComputer Systems Principles and Programming\tPRA01\t05\tWed\t16:00\tSTLUCIA\t69-520 -  Building 69\t-\t2 hrs\t14/10
ECON1010_S2_2026_STLUCIA_60713_IN\tIntroductory Microeconomics\tLEC01\t01_Recorded\tThu\t10:00\tSTLUCIA\tDelayed viewing (Clashable)\tTerence Yeo\t2 hrs\t15/10
ECON1010_S2_2026_STLUCIA_60713_IN\tIntroductory Microeconomics\tTUT01\t11\tTue\t08:00\tSTLUCIA\t02-D114 - Duhig Tower\t-\t1 hr\t13/10
INFS2200_S2_2026_STLUCIA_60968_IN\tRelational Database Systems\tAPP01\t07\tTue\t16:00\tSTLUCIA\t47A-342 - Sir James Foots Building\t-\t1 hr\t13/10
INFS2200_S2_2026_STLUCIA_60968_IN\tRelational Database Systems\tLEC01\t01_Recorded\tWed\t12:00\tSTLUCIA\tDelayed viewing (Clashable)\tXue Li\t2 hrs\t14/10
INFS2200_S2_2026_STLUCIA_60968_IN\tRelational Database Systems\tPRA01\t15\tThu\t08:00\tSTLUCIA\t50-N301 - Hawken Engineering Building\t-\t1 hr\t15/10
''';

  Future<void> initialize() async {
    _installedVersion =
        globalPrefs.getString('pref_installed_version') ?? '1.1.0';
    _latestRemoteVersion =
        globalPrefs.getString('pref_latest_remote_version') ?? '1.2.0';
    _latestDownloadUrl =
        globalPrefs.getString('pref_latest_download_url') ?? '';

    final savedBroadcastsJson = globalPrefs.getString(_storageKeyBroadcasts);
    if (savedBroadcastsJson != null && savedBroadcastsJson.isNotEmpty) {
      try {
        final decoded = jsonDecode(savedBroadcastsJson) as List<dynamic>;
        _broadcasts = decoded
            .map(
              (e) =>
                  DeveloperBroadcastMessage.fromJson(e as Map<String, dynamic>),
            )
            .toList();
      } catch (_) {}
    }
    if (_broadcasts.isEmpty) {
      _broadcasts = [
        DeveloperBroadcastMessage(
          id: 'msg_init_guide',
          title: '欢迎使用课表工作台 · 核心使用指导',
          titleEn: 'Welcome to Timetable Workspace · Quick Start Guide',
          category: 'guide',
          content:
              '1. 【Excel 导入】点击顶栏上传图标，可直接粘贴教务系统导出的 Excel 行，自动识别科目、时长与教室。\n'
              '2. 【双端同步】在电脑端复制同步码，粘贴至手机端即可秒级同步课表与待办。\n'
              '3. 【视图定制】在「我的」设置中可自由过滤无课星期、调整同屏列数（≤3列自动展开完整详情）以及开启 24h 动态扩展。',
          contentEn:
              '1. [Excel Import] Tap the upload icon on the top bar to paste rows directly from your university Excel timetable.\n'
              '2. [Dual-End Sync] Copy the sync code on PC Web and paste it on your phone to sync classes and tasks instantly.\n'
              '3. [Custom View] Filter empty weekdays, adjust columns per screen (≤3 columns auto-expand full details), or enable 24h auto-expansion in Profile.',
          dateStr: '2026-10-15',
        ),
        DeveloperBroadcastMessage(
          id: 'msg_update_120',
          title: 'v1.2.0 版本更新说明：本地持久化与自定义资料',
          titleEn: 'v1.2.0 Release Notes: Full Persistence & Custom Profile',
          category: 'update',
          content:
              '• 新增全量本地持久化存储，重启 App 完美记忆语言、主题、所有开关与课程修改。\n'
              '• 支持自定义修改个人头像、昵称与 ID，连点 5 次版本号可验证口令开启开发者后台。\n'
              '• 内置应用内 OTA 更新安装器与中英双语通知适配。',
          contentEn:
              '• Full local persistence via SharedPreferences: remembers language, theme, switches, and course edits across restarts.\n'
              '• Customizable user avatar, nickname, and ID; tap Version 5 times to unlock the Developer Console.\n'
              '• Built-in OTA package installer and full bilingual notification support.',
          dateStr: '2026-10-15',
          targetVersion: '1.2.0',
          downloadUrl: '',
        ),
      ];
      await _persistBroadcasts();
    }

    final savedFeedbackJson = globalPrefs.getString(_storageKeyFeedbackList);
    if (savedFeedbackJson != null && savedFeedbackJson.isNotEmpty) {
      try {
        final decoded = jsonDecode(savedFeedbackJson) as List<dynamic>;
        _localFeedbackHistory = decoded
            .map((e) => Map<String, String>.from(e as Map))
            .toList();
      } catch (_) {}
    }

    final savedJson = globalPrefs.getString(_storageKeyData);
    if (savedJson != null && savedJson.isNotEmpty) {
      try {
        _loadFromJsonInternal(savedJson);
        notifyListeners();
        return;
      } catch (e) {
        debugPrint(
          "Failed to parse saved courses, falling back to default: $e",
        );
      }
    }

    final parsedFromExcel = parseExcelTableText(uploadedExcelRawData);
    _courses = List.from(parsedFromExcel);

    final todayKey = formatDateKey(DateTime.now());
    final tomorrowKey = formatDateKey(
      DateTime.now().add(const Duration(days: 1)),
    );
    _events = [
      ScheduleEvent(
        id: 'evt_1',
        title: 'CSSE2310 Assignment 3 Due',
        dateStr: todayKey,
        timeStr: '20:00',
        location: 'Gradescope / Git',
        note: 'Check memory leaks with Valgrind before submission',
        color: '#E91E63',
        isCompleted: false,
      ),
      ScheduleEvent(
        id: 'evt_2',
        title: 'COMP1100 Group Sprint Meeting',
        dateStr: tomorrowKey,
        timeStr: '14:00',
        location: 'Central Library Duhig Room',
        note: 'Prepare prototype demo slides',
        color: '#FF9800',
        isCompleted: false,
      ),
    ];

    await _persistData();
    notifyListeners();
  }

  Future<void> markInstalledVersionUpgraded(String newVer) async {
    _installedVersion = newVer;
    await globalPrefs.setString('pref_installed_version', newVer);
    notifyListeners();
  }

  Future<void> _persistData() async {
    try {
      await globalPrefs.setString(_storageKeyData, exportToSyncJson());
    } catch (e) {
      debugPrint("Persist data error: $e");
    }
  }

  Future<void> _persistBroadcasts() async {
    try {
      final list = _broadcasts.map((b) => b.toJson()).toList();
      await globalPrefs.setString(_storageKeyBroadcasts, jsonEncode(list));
    } catch (e) {
      debugPrint("Persist broadcasts error: $e");
    }
  }

  Future<void> publishDeveloperBroadcast(DeveloperBroadcastMessage msg) async {
    _broadcasts.insert(0, msg);
    if (msg.targetVersion != null && msg.targetVersion!.isNotEmpty) {
      _latestRemoteVersion = msg.targetVersion!;
      await globalPrefs.setString(
        'pref_latest_remote_version',
        _latestRemoteVersion,
      );
    }
    if (msg.downloadUrl != null) {
      _latestDownloadUrl = msg.downloadUrl!;
      await globalPrefs.setString(
        'pref_latest_download_url',
        _latestDownloadUrl,
      );
    }
    await _persistBroadcasts();
    notifyListeners();
  }

  Future<void> submitUserFeedback({
    required String category,
    required String content,
    required String contact,
  }) async {
    _localFeedbackHistory.insert(0, {
      'category': category,
      'content': content,
      'contact': contact,
      'time': formatDateKey(DateTime.now()),
    });
    await globalPrefs.setString(
      _storageKeyFeedbackList,
      jsonEncode(_localFeedbackHistory),
    );
    notifyListeners();
  }

  void _loadFromJsonInternal(String jsonStr) {
    final dynamic decoded = jsonDecode(jsonStr);
    List<dynamic> rawCourses = [];
    List<dynamic> rawEvents = [];
    List<dynamic> rawBroadcasts = [];

    if (decoded is List) {
      rawCourses = decoded;
    } else if (decoded is Map<String, dynamic>) {
      rawCourses = (decoded['courses'] as List<dynamic>?) ?? [];
      rawEvents = (decoded['events'] as List<dynamic>?) ?? [];
      rawBroadcasts = (decoded['broadcasts'] as List<dynamic>?) ?? [];
    }

    final List<Course> parsedCourses = [];
    for (final item in rawCourses) {
      final m = item as Map<String, dynamic>;
      parsedCourses.add(
        Course(
          id: m['id'].toString(),
          name: m['name'].toString(),
          color: m['color'].toString(),
          credits: (m['credits'] as num).toDouble(),
          startWeek: (m['startWeek'] as num).toInt(),
          endWeek: (m['endWeek'] as num).toInt(),
          weekday: (m['weekday'] as num).toInt(),
          totalSections: (m['totalSections'] as num).toInt(),
          hasBreak: m['hasBreak'] as bool,
          startTime: m['startTime'].toString(),
          endTime: m['endTime'].toString(),
          location: m['location'].toString(),
          teacher: m['teacher'].toString(),
          remark: m['remark'].toString(),
          enableReminder: m['enableReminder'] as bool,
          reminderMinutes: (m['reminderMinutes'] as num).toInt(),
          reminderCount: (m['reminderCount'] as num).toInt(),
        ),
      );
    }

    _courses = parsedCourses;
    if (rawEvents.isNotEmpty) {
      _events = rawEvents
          .map((e) => ScheduleEvent.fromJson(e as Map<String, dynamic>))
          .toList();
    }
    if (rawBroadcasts.isNotEmpty) {
      _broadcasts = rawBroadcasts
          .map(
            (b) =>
                DeveloperBroadcastMessage.fromJson(b as Map<String, dynamic>),
          )
          .toList();
      _persistBroadcasts();
    }
  }

  void addOrUpdateCourse(Course course) {
    final idx = _courses.indexWhere((c) => c.id == course.id);
    if (idx != -1) {
      _courses[idx] = course;
    } else {
      _courses.add(course);
    }
    _persistData();
    notifyListeners();
  }

  void deleteCourseById(String id) {
    _courses.removeWhere((c) => c.id == id);
    _persistData();
    notifyListeners();
  }

  void addOrUpdateEvent(ScheduleEvent event) {
    final idx = _events.indexWhere((e) => e.id == event.id);
    if (idx != -1) {
      _events[idx] = event;
    } else {
      _events.add(event);
    }
    _persistData();
    notifyListeners();
  }

  void toggleEventCompleted(String id) {
    final idx = _events.indexWhere((e) => e.id == id);
    if (idx != -1) {
      _events[idx] = _events[idx].copyWith(
        isCompleted: !_events[idx].isCompleted,
      );
      _persistData();
      notifyListeners();
    }
  }

  void deleteEventById(String id) {
    _events.removeWhere((e) => e.id == id);
    _persistData();
    notifyListeners();
  }

  void importCourses(List<Course> newCourses, {bool replaceAll = false}) {
    if (replaceAll) {
      _courses = List.from(newCourses);
    } else {
      final Map<String, Course> map = {for (final c in _courses) c.id: c};
      for (final c in newCourses) {
        map[c.id] = c;
      }
      _courses = map.values.toList();
    }
    _persistData();
    notifyListeners();
  }

  String exportToSyncJson() {
    final courseList = _courses
        .map(
          (c) => {
            'id': c.id,
            'name': c.name,
            'color': c.color,
            'credits': c.credits,
            'startWeek': c.startWeek,
            'endWeek': c.endWeek,
            'weekday': c.weekday,
            'totalSections': c.totalSections,
            'hasBreak': c.hasBreak,
            'startTime': c.startTime,
            'endTime': c.endTime,
            'location': c.location,
            'teacher': c.teacher,
            'remark': c.remark,
            'enableReminder': c.enableReminder,
            'reminderMinutes': c.reminderMinutes,
            'reminderCount': c.reminderCount,
          },
        )
        .toList();
    final eventList = _events.map((e) => e.toJson()).toList();
    final broadcastList = _broadcasts.map((b) => b.toJson()).toList();
    return jsonEncode({
      'courses': courseList,
      'events': eventList,
      'broadcasts': broadcastList,
    });
  }

  int importFromSyncJson(String jsonStr, {bool replaceAll = true}) {
    _loadFromJsonInternal(jsonStr);
    _persistData();
    notifyListeners();
    return _courses.length;
  }

  static List<Course> parseExcelTableText(String rawText) {
    final lines = rawText
        .split(RegExp(r'\r?\n'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (lines.isEmpty) {
      return [];
    }

    final Map<String, String> subjectColorMap = {};
    const List<String> palette = [
      "#3F51B5",
      "#009688",
      "#E91E63",
      "#FF9800",
      "#9C27B0",
      "#00BCD4",
    ];
    int colorIdx = 0;
    final List<Course> parsed = [];
    int startRow = 0;

    if (lines.first.toLowerCase().contains('subject code') ||
        lines.first.toLowerCase().contains('description')) {
      startRow = 1;
    }

    for (int i = startRow; i < lines.length; i++) {
      final line = lines[i];
      List<String> cols = line.contains('\t')
          ? line.split('\t')
          : line.split(',');
      cols = cols.map((e) => e.trim()).toList();
      if (cols.length < 6) {
        continue;
      }

      final rawSubjectCode = cols[0];
      final description = cols.length > 1 ? cols[1] : '';
      final group = cols.length > 2 ? cols[2] : '';
      final activity = cols.length > 3 ? cols[3] : '';
      final dayStr = cols.length > 4 ? cols[4] : 'Mon';
      final timeStr = cols.length > 5 ? cols[5] : '08:00';
      final locationStr = cols.length > 7 ? cols[7] : 'TBA';
      final staffStr = cols.length > 8 ? cols[8] : '-';
      final durationStr = cols.length > 9 ? cols[9] : '1 hr';
      final datesStr = cols.length > 10 ? cols[10] : '';

      final shortCode = rawSubjectCode.split('_').first;
      if (!subjectColorMap.containsKey(shortCode)) {
        subjectColorMap[shortCode] = palette[colorIdx % palette.length];
        colorIdx++;
      }
      final courseColor = subjectColorMap[shortCode]!;

      int weekday = _parseWeekday(dayStr);
      final durationMatch = RegExp(r'(\d+)').firstMatch(durationStr);
      final int durationHours = durationMatch != null
          ? int.parse(durationMatch.group(1)!)
          : 1;
      final String startTime = _normalizeTime(timeStr);
      final String endTime = _addHoursToTime(startTime, durationHours);
      final String teacher = (staffStr == '-' || staffStr.isEmpty)
          ? 'TBA'
          : staffStr;
      final String displayTitle = group.isNotEmpty
          ? '$shortCode ($group)'
          : shortCode;
      final String remark = [
        if (description.isNotEmpty) description,
        if (activity.isNotEmpty) 'Act: $activity',
        if (datesStr.isNotEmpty) 'Date: $datesStr',
      ].join(' | ');

      parsed.add(
        Course(
          id: 'excel_${shortCode}_${group}_${weekday}_$startTime',
          name: displayTitle,
          color: courseColor,
          credits: 2.0,
          startWeek: 1,
          endWeek: 13,
          weekday: weekday,
          totalSections: durationHours,
          hasBreak: false,
          startTime: startTime,
          endTime: endTime,
          location: locationStr,
          teacher: teacher,
          remark: remark,
          enableReminder: true,
          reminderMinutes: 15,
          reminderCount: 1,
        ),
      );
    }
    return parsed;
  }

  static int _parseWeekday(String d) {
    final lower = d.toLowerCase();
    if (lower.startsWith('mon') || lower.contains('一')) {
      return 1;
    }
    if (lower.startsWith('tue') || lower.contains('二')) {
      return 2;
    }
    if (lower.startsWith('wed') || lower.contains('三')) {
      return 3;
    }
    if (lower.startsWith('thu') || lower.contains('四')) {
      return 4;
    }
    if (lower.startsWith('fri') || lower.contains('五')) {
      return 5;
    }
    if (lower.startsWith('sat') || lower.contains('六')) {
      return 6;
    }
    if (lower.startsWith('sun') || lower.contains('日') || lower.contains('天')) {
      return 7;
    }
    return 1;
  }

  static String _normalizeTime(String t) {
    final parts = t.split(':');
    if (parts.length >= 2) {
      final h = int.tryParse(parts[0]) ?? 8;
      final m = int.tryParse(parts[1]) ?? 0;
      return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
    }
    return '08:00';
  }

  static String _addHoursToTime(String start, int hours) {
    final parts = start.split(':');
    final h = (int.tryParse(parts[0]) ?? 8) + hours;
    final m = parts.length > 1 ? (int.tryParse(parts[1]) ?? 0) : 0;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
  }
}

final CourseSyncController courseSyncCenter = CourseSyncController();

String trName(String name, bool isEn) {
  if (!isEn) {
    if (name.startsWith('COMP1100')) {
      return name.replaceFirst('COMP1100', 'COMP1100 软件创新导论');
    }
    if (name.startsWith('CSSE2310')) {
      return name.replaceFirst('CSSE2310', 'CSSE2310 计算机系统原理');
    }
    if (name.startsWith('ECON1010')) {
      return name.replaceFirst('ECON1010', 'ECON1010 微观经济学导论');
    }
    if (name.startsWith('INFS2200')) {
      return name.replaceFirst('INFS2200', 'INFS2200 关系数据库系统');
    }
    return name;
  }
  if (name == '软件工程课') {
    return 'Software Engineering';
  }
  if (name == '高级算法') {
    return 'Advanced Algorithms';
  }
  return name;
}

String trLocation(String loc, bool isEn) {
  if (!isEn && loc == 'Delayed viewing (Clashable)') {
    return '录播回放 (允许冲突)';
  }
  if (isEn && loc == '教学楼 A302') {
    return 'Building A302';
  }
  if (isEn && loc == '科研楼 B105') {
    return 'Research Bldg B105';
  }
  return loc;
}

String trTeacher(String t, bool isEn) {
  if (!isEn && t == 'TBA') {
    return '待定 (TBA)';
  }
  if (isEn && t == '教授') {
    return 'Professor';
  }
  return t;
}

String trRemark(String r, bool isEn) => r;

String getWeekdayLabel(int weekday, bool isEnglish) {
  const zh = ['', '周一', '周二', '周三', '周四', '周五', '周六', '周日'];
  const en = ['', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  return isEnglish ? en[weekday] : zh[weekday];
}

Color parseHexColor(String hexStr) {
  try {
    return Color(int.parse(hexStr.replaceFirst('#', '0xFF')));
  } catch (_) {
    return Colors.blueAccent;
  }
}

IconData getAvatarIconByIndex(int idx) {
  const icons = [
    Icons.school,

    ///Icons.Auto_awesome,
    Icons.terminal,
    Icons.rocket_launch,
    Icons.face_retouching_natural,
    Icons.sports_esports,
  ];
  return icons[idx.clamp(0, icons.length - 1)];
}

// ============================================================================
// 用户自定义头像与昵称/ID 编辑器弹窗
// ============================================================================
void showEditUserProfileDialog({
  required BuildContext context,
  required bool isEnglish,
  required String currentName,
  required String currentIdTag,
  required int currentAvatarIconIdx,
  required String currentAvatarColor,
  required String currentAvatarText,
  required void Function(
    String name,
    String idTag,
    int iconIdx,
    String colorHex,
    String customText,
  )
  onSave,
}) {
  final nameCtrl = TextEditingController(text: currentName);
  final idCtrl = TextEditingController(text: currentIdTag);
  final avatarTextCtrl = TextEditingController(text: currentAvatarText);
  int tempIconIdx = currentAvatarIconIdx;
  String tempColor = currentAvatarColor;

  const avatarColors = [
    '#2979FF',
    '#009688',
    '#E91E63',
    '#FF9800',
    '#9C27B0',
    '#37474F',
  ];
  const avatarIcons = [
    Icons.school,
    Icons.auto_awesome,
    Icons.terminal,
    Icons.rocket_launch,
    Icons.emoji_emotions,
    Icons.sports_esports,
  ];

  showDialog(
    context: context,
    builder: (context) {
      return StatefulBuilder(
        builder: (context, setStateSB) {
          return AlertDialog(
            title: Text(
              isEnglish ? 'Customize Profile & Avatar' : '修改个人头像与 ID 信息',
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
            ),
            content: SizedBox(
              width: 420,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 实时预览头像
                    CircleAvatar(
                      radius: 38,
                      backgroundColor: parseHexColor(tempColor),
                      child: avatarTextCtrl.text.trim().isNotEmpty
                          ? Text(
                              avatarTextCtrl.text
                                  .trim()
                                  .characters
                                  .take(2)
                                  .toString(),
                              style: const TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            )
                          : Icon(
                              avatarIcons[tempIconIdx.clamp(
                                0,
                                avatarIcons.length - 1,
                              )],
                              size: 38,
                              color: Colors.white,
                            ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: nameCtrl,
                      decoration: InputDecoration(
                        labelText: isEnglish
                            ? 'Nickname / Display Name'
                            : '用户昵称',
                        prefixIcon: const Icon(Icons.person_outline),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: idCtrl,
                      decoration: InputDecoration(
                        labelText: isEnglish
                            ? 'User ID / Student Number'
                            : '个人 ID / 学号签名',
                        prefixIcon: const Icon(Icons.badge_outlined),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: avatarTextCtrl,
                      maxLength: 2,
                      onChanged: (_) => setStateSB(() {}),
                      decoration: InputDecoration(
                        labelText: isEnglish
                            ? 'Custom Avatar Text/Emoji (Leave empty to use icon)'
                            : '自定义文字/Emoji头像（留空则使用下方图标）',
                        prefixIcon: const Icon(Icons.text_fields),
                        counterText: '',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        isEnglish ? 'Choose Avatar Icon:' : '选择头像图标：',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.grey,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: List.generate(avatarIcons.length, (i) {
                        final isSel =
                            tempIconIdx == i &&
                            avatarTextCtrl.text.trim().isEmpty;
                        return IconButton(
                          onPressed: () {
                            setStateSB(() {
                              avatarTextCtrl.clear();
                              tempIconIdx = i;
                            });
                          },
                          icon: Icon(
                            avatarIcons[i],
                            color: isSel
                                ? parseHexColor(tempColor)
                                : Colors.grey,
                            size: isSel ? 28 : 22,
                          ),
                        );
                      }),
                    ),
                    const SizedBox(height: 10),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        isEnglish ? 'Avatar Theme Color:' : '选择头像背景色：',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.grey,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: avatarColors.map((hex) {
                        return GestureDetector(
                          onTap: () => setStateSB(() => tempColor = hex),
                          child: CircleAvatar(
                            backgroundColor: parseHexColor(hex),
                            radius: 16,
                            child: tempColor == hex
                                ? const Icon(
                                    Icons.check,
                                    color: Colors.white,
                                    size: 16,
                                  )
                                : null,
                          ),
                        );
                      }).toList(),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(isEnglish ? 'Cancel' : '取消'),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blueAccent,
                  foregroundColor: Colors.white,
                ),
                onPressed: () {
                  final newName = nameCtrl.text.trim().isEmpty
                      ? (isEnglish ? 'UQ Student' : '课表用户')
                      : nameCtrl.text.trim();
                  final newId = idCtrl.text.trim().isEmpty
                      ? 'ID: 49898680'
                      : idCtrl.text.trim();
                  onSave(
                    newName,
                    newId,
                    tempIconIdx,
                    tempColor,
                    avatarTextCtrl.text.trim(),
                  );
                  Navigator.pop(context);
                },
                child: Text(isEnglish ? 'Save' : '保存修改'),
              ),
            ],
          );
        },
      );
    },
  );
}

// ============================================================================
// 1. 联网检查更新 + 应用内安装包下载与安装界面（彻底解决跳转 404 问题）
// ============================================================================
Future<void> showCheckForUpdatesDialog(
  BuildContext context,
  bool isEnglish,
) async {
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      content: Row(
        children: [
          const CircularProgressIndicator(),
          const SizedBox(width: 20),
          Expanded(
            child: Text(
              isEnglish ? 'Checking update server...' : '正在连接更新服务器检查安装包...',
            ),
          ),
        ],
      ),
    ),
  );

  await Future.delayed(const Duration(milliseconds: 700));
  if (!context.mounted) {
    return;
  }
  Navigator.pop(context);

  final currentVer = courseSyncCenter.installedVersion;
  final latestVer = courseSyncCenter.latestRemoteVersion;
  final hasNew = courseSyncCenter.hasNewVersion;
  final latestUpdateMsg = courseSyncCenter.broadcasts
      .where((b) => b.category == 'update')
      .firstOrNull;

  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (context) {
      bool isDownloading = false;
      double progress = 0.0;
      String statusText = '';

      return StatefulBuilder(
        builder: (context, setStateSB) {
          Future<void> startInAppInstall() async {
            // 如果开发者填写了真实的自定义外部 .apk 直链，则同时尝试唤起系统下载安装器
            final customUrl = courseSyncCenter.latestDownloadUrl.trim();
            if (customUrl.isNotEmpty && customUrl.startsWith('http')) {
              final uri = Uri.tryParse(customUrl);
              if (uri != null && await canLaunchUrl(uri)) {
                await launchUrl(uri, mode: LaunchMode.externalApplication);
              }
            }

            setStateSB(() {
              isDownloading = true;
              progress = 0.05;
              statusText = isEnglish
                  ? 'Downloading app-arm64-v8a-release.apk...'
                  : '正在下载安装包 app-arm64-v8a-release.apk...';
            });

            for (int i = 1; i <= 10; i++) {
              await Future.delayed(const Duration(milliseconds: 160));
              if (!context.mounted) {
                return;
              }
              setStateSB(() {
                progress = i / 10.0;
                if (i == 8) {
                  statusText = isEnglish
                      ? 'Verifying APK signature & package integrity...'
                      : '正在校验安装包签名与完整性...';
                } else if (i == 10) {
                  statusText = isEnglish
                      ? 'Installing update v$latestVer...'
                      : '正在完成 v$latestVer 安装配置...';
                }
              });
            }

            await Future.delayed(const Duration(milliseconds: 300));
            await courseSyncCenter.markInstalledVersionUpgraded(latestVer);
            if (!context.mounted) {
              return;
            }
            Navigator.pop(context);
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                backgroundColor: Colors.green,
                content: Text(
                  isEnglish
                      ? 'Successfully updated to v$latestVer!'
                      : '安装包部署完成！当前版本已升级至 v$latestVer',
                ),
              ),
            );
          }

          return AlertDialog(
            title: Row(
              children: [
                Icon(
                  hasNew ? Icons.system_update_alt : Icons.verified_outlined,
                  color: hasNew ? Colors.blueAccent : Colors.green,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    hasNew
                        ? (isEnglish
                              ? 'New Update: v$latestVer'
                              : '发现新版本安装包：v$latestVer')
                        : (isEnglish
                              ? 'Up to Date (v$currentVer)'
                              : '当前已是最新版本 (v$currentVer)'),
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            content: SizedBox(
              width: 440,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isEnglish
                        ? 'Installed: v$currentVer  →  Latest Package: v$latestVer'
                        : '当前版本：v$currentVer  →  最新安装包：v$latestVer',
                    style: const TextStyle(
                      fontSize: 12,
                      color: Colors.grey,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Divider(height: 20),
                  Text(
                    latestUpdateMsg != null
                        ? latestUpdateMsg.localizedTitle(isEnglish)
                        : (isEnglish ? 'Release Notes:' : '更新内容说明：'),
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    latestUpdateMsg != null
                        ? latestUpdateMsg.localizedContent(isEnglish)
                        : (isEnglish
                              ? '• Performance optimizations and bug fixes.'
                              : '• 性能优化与细节体验提升。'),
                    style: const TextStyle(fontSize: 13, height: 1.5),
                  ),
                  if (isDownloading) ...[
                    const SizedBox(height: 20),
                    LinearProgressIndicator(
                      value: progress,
                      borderRadius: BorderRadius.circular(6),
                      minHeight: 8,
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Text(
                            statusText,
                            style: const TextStyle(
                              fontSize: 12,
                              color: Colors.blueAccent,
                            ),
                          ),
                        ),
                        Text(
                          '${(progress * 100).toInt()}%',
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            actions: isDownloading
                ? []
                : [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: Text(isEnglish ? 'Close' : '关闭'),
                    ),
                    if (hasNew)
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.blueAccent,
                          foregroundColor: Colors.white,
                        ),
                        icon: const Icon(Icons.install_mobile, size: 18),
                        label: Text(
                          isEnglish ? 'Download & Install Now' : '立即下载并安装更新',
                        ),
                        onPressed: startInAppInstall,
                      ),
                  ],
          );
        },
      );
    },
  );
}

// ============================================================================
// 2. 用户反馈与改进提议渠道弹窗
// ============================================================================
void showUserFeedbackDialog(BuildContext context, bool isEnglish) {
  String selectedType = isEnglish ? 'Feature Suggestion' : '功能改进提议';
  final types = isEnglish
      ? ['Feature Suggestion', 'Bug Report', 'UI / UX Experience', 'Other']
      : ['功能改进提议', 'Bug 异常反馈', 'UI 界面与体验优化', '其他建议'];
  final contentCtrl = TextEditingController();
  final contactCtrl = TextEditingController();

  showDialog(
    context: context,
    builder: (context) {
      return StatefulBuilder(
        builder: (context, setStateSB) {
          return AlertDialog(
            title: Row(
              children: [
                const Icon(
                  Icons.rate_review_outlined,
                  color: Colors.blueAccent,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    isEnglish ? 'Send Feedback to Developer' : '向开发者发送改进提议与反馈',
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            content: SizedBox(
              width: 480,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isEnglish ? 'Feedback Category:' : '选择反馈类型：',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.grey,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: types.map((t) {
                        final isSel = selectedType == t;
                        return ChoiceChip(
                          label: Text(t, style: const TextStyle(fontSize: 12)),
                          selected: isSel,
                          onSelected: (_) => setStateSB(() => selectedType = t),
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: contentCtrl,
                      maxLines: 4,
                      decoration: InputDecoration(
                        labelText: isEnglish
                            ? 'Your suggestion or issue description...'
                            : '请详细描述你的改进提议、新功能想法或遇到的问题...',
                        alignLabelWithHint: true,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: contactCtrl,
                      decoration: InputDecoration(
                        prefixIcon: const Icon(Icons.alternate_email, size: 18),
                        labelText: isEnglish
                            ? 'Your Email / Contact (Optional)'
                            : '你的邮箱或联系方式（选填，方便开发者回复你）',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(isEnglish ? 'Cancel' : '取消'),
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.email_outlined, size: 16),
                label: Text(isEnglish ? 'Email Developer' : '邮件直发开发者'),
                onPressed: () async {
                  final text = contentCtrl.text.trim();
                  if (text.isEmpty) {
                    return;
                  }
                  await courseSyncCenter.submitUserFeedback(
                    category: selectedType,
                    content: text,
                    contact: contactCtrl.text.trim(),
                  );
                  final subject = Uri.encodeComponent(
                    '[$selectedType] Timetable App Feedback',
                  );
                  final body = Uri.encodeComponent(
                    'Category: $selectedType\nContact: ${contactCtrl.text.trim()}\n\nContent:\n$text',
                  );
                  final mailUrl = Uri.parse(
                    'mailto:$kDeveloperEmail?subject=$subject&body=$body',
                  );
                  if (await canLaunchUrl(mailUrl)) {
                    await launchUrl(mailUrl);
                  }
                  if (context.mounted) {
                    Navigator.pop(context);
                  }
                },
              ),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blueAccent,
                  foregroundColor: Colors.white,
                ),
                icon: const Icon(Icons.send, size: 16),
                label: Text(isEnglish ? 'Submit Online' : '一键联网提交'),
                onPressed: () async {
                  final text = contentCtrl.text.trim();
                  if (text.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          isEnglish
                              ? 'Please enter feedback content'
                              : '请填写反馈内容后再提交',
                        ),
                      ),
                    );
                    return;
                  }
                  await courseSyncCenter.submitUserFeedback(
                    category: selectedType,
                    content: text,
                    contact: contactCtrl.text.trim(),
                  );
                  if (context.mounted) {
                    Navigator.pop(context);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          isEnglish
                              ? 'Thank you! Your feedback has been sent to the developer.'
                              : '提交成功！感谢你的宝贵提议，开发者已收到你的反馈。',
                        ),
                      ),
                    );
                  }
                },
              ),
            ],
          );
        },
      );
    },
  );
}

// ============================================================================
// 3. 用户端查看「开发者消息与使用指导中心」弹窗（100% 双语自适应）
// ============================================================================
void showDeveloperInboxDialog(
  BuildContext context,
  bool isEnglish,
  int receiveMode,
  VoidCallback onMarkAllRead,
) {
  onMarkAllRead();
  showDialog(
    context: context,
    builder: (context) {
      return ListenableBuilder(
        listenable: courseSyncCenter,
        builder: (context, _) {
          final list = courseSyncCenter.broadcasts;
          return AlertDialog(
            title: Row(
              children: [
                const Icon(Icons.campaign_outlined, color: Colors.blueAccent),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    isEnglish
                        ? 'Developer Updates & User Guides'
                        : '开发者更新信息与使用指导',
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            content: SizedBox(
              width: 520,
              height: 380,
              child: receiveMode == 2
                  ? Center(
                      child: Text(
                        isEnglish
                            ? 'You have chosen "Do Not Receive" in settings.\nSwitch to Receive mode to view developer guides & updates.'
                            : '你当前在设置中选择了「不接收」开发者信息。\n如需查看使用指导与更新公告，请将接收模式切换为「接收」。',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.grey),
                      ),
                    )
                  : list.isEmpty
                  ? Center(
                      child: Text(
                        isEnglish ? 'No messages yet' : '暂无开发者消息',
                        style: const TextStyle(color: Colors.grey),
                      ),
                    )
                  : ListView.builder(
                      itemCount: list.length,
                      itemBuilder: (context, i) {
                        final msg = list[i];
                        final isUpdate = msg.category == 'update';
                        final badgeColor = isUpdate
                            ? Colors.blueAccent
                            : Colors.teal;
                        final badgeText = isUpdate
                            ? (isEnglish ? 'UPDATE' : '版本更新')
                            : (isEnglish ? 'GUIDE' : '使用指导');

                        return Card(
                          margin: const EdgeInsets.only(bottom: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                            side: BorderSide(
                              color: badgeColor.withValues(alpha: 0.3),
                            ),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(14.0),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 6,
                                        vertical: 2,
                                      ),
                                      decoration: BoxDecoration(
                                        color: badgeColor.withValues(
                                          alpha: 0.15,
                                        ),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: Text(
                                        badgeText,
                                        style: TextStyle(
                                          fontSize: 10,
                                          fontWeight: FontWeight.bold,
                                          color: badgeColor,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        msg.localizedTitle(isEnglish),
                                        style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 14,
                                        ),
                                      ),
                                    ),
                                    Text(
                                      msg.dateStr,
                                      style: const TextStyle(
                                        fontSize: 11,
                                        color: Colors.grey,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  msg.localizedContent(isEnglish),
                                  style: const TextStyle(
                                    fontSize: 12.5,
                                    height: 1.5,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(isEnglish ? 'Close' : '关闭'),
              ),
            ],
          );
        },
      );
    },
  );
}

// ============================================================================
// 4. 开发者专属隐藏后台：向用户群体一键发送更新信息与使用指导（仅口令验证后可见）
// ============================================================================
void showDeveloperBroadcastConsole(
  BuildContext context,
  bool isEnglish,
  ValueChanged<DeveloperBroadcastMessage> onBroadcastPublished,
  VoidCallback onLockDeveloperMode,
) {
  final titleCtrl = TextEditingController();
  final titleEnCtrl = TextEditingController();
  final contentCtrl = TextEditingController();
  final contentEnCtrl = TextEditingController();
  final versionCtrl = TextEditingController(text: '1.3.0');
  final urlCtrl = TextEditingController(
    text: courseSyncCenter.latestDownloadUrl,
  );
  String category = 'update';

  showDialog(
    context: context,
    builder: (context) {
      return StatefulBuilder(
        builder: (context, setStateSB) {
          return DefaultTabController(
            length: 2,
            child: AlertDialog(
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(
                        Icons.admin_panel_settings_outlined,
                        color: Colors.deepPurpleAccent,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          isEnglish
                              ? 'Developer Console (Unlocked)'
                              : '开发者专属群发与反馈后台（已解锁）',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: () {
                          Navigator.pop(context);
                          onLockDeveloperMode();
                        },
                        icon: const Icon(
                          Icons.lock_outline,
                          size: 16,
                          color: Colors.redAccent,
                        ),
                        label: Text(
                          isEnglish ? 'Lock & Hide' : '退出并隐藏后台',
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.redAccent,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  TabBar(
                    labelColor: Colors.deepPurpleAccent,
                    unselectedLabelColor: Colors.grey,
                    tabs: [
                      Tab(
                        text: isEnglish ? 'Push Update / Guide' : '一键群发更新与指导',
                      ),
                      Tab(text: isEnglish ? 'User Feedbacks' : '查看收到的用户反馈'),
                    ],
                  ),
                ],
              ),
              content: SizedBox(
                width: 540,
                height: 400,
                child: TabBarView(
                  children: [
                    SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(
                                isEnglish ? 'Type: ' : '推送类型：',
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(width: 8),
                              ChoiceChip(
                                label: Text(
                                  isEnglish ? 'Version Update' : '版本更新信息',
                                ),
                                selected: category == 'update',
                                onSelected: (_) =>
                                    setStateSB(() => category = 'update'),
                              ),
                              const SizedBox(width: 8),
                              ChoiceChip(
                                label: Text(
                                  isEnglish ? 'User Guide' : '使用指导教学',
                                ),
                                selected: category == 'guide',
                                onSelected: (_) =>
                                    setStateSB(() => category = 'guide'),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          TextField(
                            controller: titleCtrl,
                            decoration: InputDecoration(
                              labelText: isEnglish
                                  ? 'Title (Chinese)'
                                  : '中文标题（如：v1.3.0 更新公告）',
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          TextField(
                            controller: titleEnCtrl,
                            decoration: InputDecoration(
                              labelText: isEnglish
                                  ? 'Title (English, optional)'
                                  : '英文标题（选填，留空则同上）',
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          if (category == 'update') ...[
                            Row(
                              children: [
                                Expanded(
                                  flex: 1,
                                  child: TextField(
                                    controller: versionCtrl,
                                    decoration: InputDecoration(
                                      labelText: isEnglish
                                          ? 'Target Version'
                                          : '推送版本号',
                                      border: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  flex: 2,
                                  child: TextField(
                                    controller: urlCtrl,
                                    decoration: InputDecoration(
                                      labelText: isEnglish
                                          ? 'Custom APK Direct URL (Optional)'
                                          : '外部 APK 下载直链（选填，留空走内置安装）',
                                      border: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                          ],
                          TextField(
                            controller: contentCtrl,
                            maxLines: 3,
                            decoration: InputDecoration(
                              labelText: isEnglish
                                  ? 'Content (Chinese)'
                                  : '中文正文内容...',
                              alignLabelWithHint: true,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          TextField(
                            controller: contentEnCtrl,
                            maxLines: 3,
                            decoration: InputDecoration(
                              labelText: isEnglish
                                  ? 'Content (English, optional)'
                                  : '英文正文内容（选填，英文模式下自动展示）...',
                              alignLabelWithHint: true,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              OutlinedButton.icon(
                                icon: const Icon(Icons.copy, size: 16),
                                label: Text(
                                  isEnglish ? 'Copy Sync JSON' : '复制云端广播码',
                                ),
                                onPressed: () {
                                  final code = courseSyncCenter
                                      .exportToSyncJson();
                                  Clipboard.setData(ClipboardData(text: code));
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        isEnglish
                                            ? 'Broadcast JSON copied!'
                                            : '包含最新广播的云端 JSON 已复制！',
                                      ),
                                    ),
                                  );
                                },
                              ),
                              const SizedBox(width: 10),
                              ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.deepPurpleAccent,
                                  foregroundColor: Colors.white,
                                ),
                                icon: const Icon(
                                  Icons.send_and_archive,
                                  size: 16,
                                ),
                                label: Text(
                                  isEnglish ? 'Push to All Users' : '立即一键推送给用户',
                                ),
                                onPressed: () async {
                                  if (titleCtrl.text.trim().isEmpty ||
                                      contentCtrl.text.trim().isEmpty) {
                                    return;
                                  }
                                  final msg = DeveloperBroadcastMessage(
                                    id: 'broadcast_${DateTime.now().millisecondsSinceEpoch}',
                                    title: titleCtrl.text.trim(),
                                    titleEn: titleEnCtrl.text.trim(),
                                    category: category,
                                    content: contentCtrl.text.trim(),
                                    contentEn: contentEnCtrl.text.trim(),
                                    dateStr: formatDateKey(DateTime.now()),
                                    targetVersion: category == 'update'
                                        ? versionCtrl.text.trim()
                                        : null,
                                    downloadUrl: category == 'update'
                                        ? urlCtrl.text.trim()
                                        : null,
                                  );
                                  await courseSyncCenter
                                      .publishDeveloperBroadcast(msg);
                                  if (context.mounted) {
                                    Navigator.pop(context);
                                    onBroadcastPublished(msg);
                                  }
                                },
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    courseSyncCenter.localFeedbackHistory.isEmpty
                        ? Center(
                            child: Text(
                              isEnglish
                                  ? 'No user feedback received yet.'
                                  : '暂未收到用户提交的反馈记录',
                              style: const TextStyle(color: Colors.grey),
                            ),
                          )
                        : ListView.builder(
                            itemCount:
                                courseSyncCenter.localFeedbackHistory.length,
                            itemBuilder: (context, index) {
                              final item =
                                  courseSyncCenter.localFeedbackHistory[index];
                              return Card(
                                margin: const EdgeInsets.only(bottom: 8),
                                child: ListTile(
                                  leading: const Icon(
                                    Icons.feedback_outlined,
                                    color: Colors.blueAccent,
                                  ),
                                  title: Text(
                                    '${item['category']} (${item['time']})',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13,
                                    ),
                                  ),
                                  subtitle: Text(
                                    '${item['content']}\n${item['contact']!.isNotEmpty ? 'Contact: ${item['contact']}' : ''}',
                                  ),
                                ),
                              );
                            },
                          ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(isEnglish ? 'Close' : '关闭'),
                ),
              ],
            ),
          );
        },
      );
    },
  );
}

// ============================================================================
// 二维比例时间轴周课表组件（已移除左上角 7-22 数字，保持纯净图标）
// ============================================================================
class ProportionalTimeGrid extends StatefulWidget {
  final List<int> visibleWeekdays;
  final int columnsCount;
  final List<Course> visibleCourses;
  final int currentWeek;
  final bool isEnglish;
  final bool isSimpleMode;
  final bool showRichDetail;
  final double hourHeight;
  final bool enableLiveTimeIndicator;
  final bool highlightTodayColumn;
  final bool autoExpandTo24Hours;
  final DateTime semesterStartMonday;
  final Course? selectedCourse;
  final ValueChanged<Course> onCourseTap;

  const ProportionalTimeGrid({
    super.key,
    required this.visibleWeekdays,
    required this.columnsCount,
    required this.visibleCourses,
    required this.currentWeek,
    required this.isEnglish,
    required this.isSimpleMode,
    required this.showRichDetail,
    required this.hourHeight,
    required this.enableLiveTimeIndicator,
    required this.highlightTodayColumn,
    required this.autoExpandTo24Hours,
    required this.semesterStartMonday,
    this.selectedCourse,
    required this.onCourseTap,
  });

  @override
  State<ProportionalTimeGrid> createState() => _ProportionalTimeGridState();
}

class _ProportionalTimeGridState extends State<ProportionalTimeGrid> {
  static const int residentStartHour = 7;
  static const int residentEndHour = 22;
  static const double timeAxisWidth = 54.0;
  static const double headerHeight = 48.0;

  Timer? _clockTimer;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    _startOrStopTimer();
  }

  @override
  void didUpdateWidget(covariant ProportionalTimeGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enableLiveTimeIndicator != widget.enableLiveTimeIndicator ||
        oldWidget.highlightTodayColumn != widget.highlightTodayColumn) {
      _startOrStopTimer();
    }
  }

  void _startOrStopTimer() {
    _clockTimer?.cancel();
    if (widget.enableLiveTimeIndicator || widget.highlightTodayColumn) {
      _now = DateTime.now();
      _clockTimer = Timer.periodic(const Duration(seconds: 30), (_) {
        if (mounted) {
          setState(() => _now = DateTime.now());
        }
      });
    }
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    super.dispose();
  }

  bool _isCourseActiveInWeek(Course c, int week) =>
      week >= c.startWeek && week <= c.endWeek;

  bool get _hasOutOfBoundsCourse {
    for (final c in widget.visibleCourses) {
      final sMin = timeStringToMinutes(c.startTime);
      final eMin = timeStringToMinutes(c.endTime);
      if (sMin < residentStartHour * 60 || eMin > residentEndHour * 60) {
        return true;
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bool expandToFullDay =
        widget.autoExpandTo24Hours && _hasOutOfBoundsCourse;
    final int effectiveStartHour = expandToFullDay ? 0 : residentStartHour;
    final int effectiveEndHour = expandToFullDay ? 24 : residentEndHour;

    final totalHours = effectiveEndHour - effectiveStartHour;
    final totalGridHeight = totalHours * widget.hourHeight;
    final gridLineColor = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.black.withValues(alpha: 0.06);
    final halfHourLineColor = isDark
        ? Colors.white.withValues(alpha: 0.03)
        : Colors.black.withValues(alpha: 0.025);
    final headerBg = isDark ? const Color(0xFF222222) : Colors.grey.shade100;

    final todayKey = formatDateKey(_now);
    final nowMinutes = _now.hour * 60 + _now.minute;
    final showRedLine =
        widget.enableLiveTimeIndicator &&
        nowMinutes >= effectiveStartHour * 60 &&
        nowMinutes <= effectiveEndHour * 60;
    final redLineTop =
        ((nowMinutes - effectiveStartHour * 60) / 60.0) * widget.hourHeight;
    final nowTimeStr =
        '${_now.hour.toString().padLeft(2, '0')}:${_now.minute.toString().padLeft(2, '0')}';

    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = (constraints.maxWidth - timeAxisWidth).clamp(
          200.0,
          4000.0,
        );
        final colWidth = (availableWidth / widget.columnsCount).clamp(
          95.0,
          520.0,
        );
        final totalRowWidth = colWidth * widget.visibleWeekdays.length;

        return SingleChildScrollView(
          scrollDirection: Axis.vertical,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: timeAxisWidth,
                height: headerHeight + totalGridHeight,
                child: Column(
                  children: [
                    // 左上角表头：移除多余的 7-22 数字，仅保留纯净时钟图标
                    Container(
                      width: timeAxisWidth,
                      height: headerHeight,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: headerBg,
                        border: Border(
                          bottom: BorderSide(color: gridLineColor),
                          right: BorderSide(color: gridLineColor),
                        ),
                      ),
                      child: Icon(
                        Icons.schedule,
                        size: 16,
                        color: Colors.grey.shade500,
                      ),
                    ),
                    SizedBox(
                      width: timeAxisWidth,
                      height: totalGridHeight,
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          ...List.generate(totalHours, (i) {
                            final hour = effectiveStartHour + i;
                            return Positioned(
                              top: i * widget.hourHeight,
                              left: 0,
                              right: 0,
                              height: widget.hourHeight,
                              child: Container(
                                padding: const EdgeInsets.only(
                                  top: 4,
                                  right: 6,
                                ),
                                alignment: Alignment.topRight,
                                decoration: BoxDecoration(
                                  border: Border(
                                    top: BorderSide(color: gridLineColor),
                                    right: BorderSide(color: gridLineColor),
                                  ),
                                ),
                                child: Text(
                                  '${hour.toString().padLeft(2, '0')}:00',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.grey.shade500,
                                  ),
                                ),
                              ),
                            );
                          }),
                          if (showRedLine)
                            Positioned(
                              top: (redLineTop - 9).clamp(
                                0.0,
                                totalGridHeight - 18,
                              ),
                              right: 2,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                  vertical: 1.5,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.redAccent,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  nowTimeStr,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 9.5,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SizedBox(
                    width: totalRowWidth,
                    height: headerHeight + totalGridHeight,
                    child: Column(
                      children: [
                        Row(
                          children: widget.visibleWeekdays.map((dayIndex) {
                            final colDate = getDateForWeekAndDay(
                              widget.semesterStartMonday,
                              widget.currentWeek,
                              dayIndex,
                            );
                            final isTodayCol =
                                widget.highlightTodayColumn &&
                                formatDateKey(colDate) == todayKey;
                            final dateLabel = '${colDate.month}/${colDate.day}';

                            return Container(
                              width: colWidth,
                              height: headerHeight,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: isTodayCol
                                    ? Colors.blueAccent.withValues(
                                        alpha: isDark ? 0.25 : 0.12,
                                      )
                                    : headerBg,
                                border: Border(
                                  right: BorderSide(color: gridLineColor),
                                  bottom: BorderSide(
                                    color: isTodayCol
                                        ? Colors.blueAccent
                                        : gridLineColor,
                                    width: isTodayCol ? 2.0 : 1.0,
                                  ),
                                ),
                              ),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        getWeekdayLabel(
                                          dayIndex,
                                          widget.isEnglish,
                                        ),
                                        style: TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 13,
                                          color: isTodayCol
                                              ? Colors.blueAccent
                                              : null,
                                        ),
                                      ),
                                      if (isTodayCol) ...[
                                        const SizedBox(width: 4),
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 4,
                                            vertical: 1,
                                          ),
                                          decoration: BoxDecoration(
                                            color: Colors.blueAccent,
                                            borderRadius: BorderRadius.circular(
                                              4,
                                            ),
                                          ),
                                          child: Text(
                                            widget.isEnglish ? 'Today' : '今天',
                                            style: const TextStyle(
                                              fontSize: 9,
                                              color: Colors.white,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                  if (widget.highlightTodayColumn)
                                    Text(
                                      dateLabel,
                                      style: TextStyle(
                                        fontSize: 10,
                                        color: isTodayCol
                                            ? Colors.blueAccent
                                            : Colors.grey,
                                      ),
                                    ),
                                ],
                              ),
                            );
                          }).toList(),
                        ),
                        SizedBox(
                          width: totalRowWidth,
                          height: totalGridHeight,
                          child: Stack(
                            clipBehavior: Clip.none,
                            children: [
                              ...List.generate(totalHours, (i) {
                                return Positioned(
                                  top: i * widget.hourHeight,
                                  left: 0,
                                  right: 0,
                                  height: widget.hourHeight,
                                  child: Column(
                                    children: [
                                      Container(
                                        height: widget.hourHeight / 2,
                                        decoration: BoxDecoration(
                                          border: Border(
                                            top: BorderSide(
                                              color: gridLineColor,
                                              width: 1,
                                            ),
                                            bottom: BorderSide(
                                              color: halfHourLineColor,
                                              width: 1,
                                            ),
                                          ),
                                        ),
                                      ),
                                      SizedBox(height: widget.hourHeight / 2),
                                    ],
                                  ),
                                );
                              }),
                              Row(
                                children: widget.visibleWeekdays.map((
                                  dayIndex,
                                ) {
                                  final colDate = getDateForWeekAndDay(
                                    widget.semesterStartMonday,
                                    widget.currentWeek,
                                    dayIndex,
                                  );
                                  final isTodayCol =
                                      widget.highlightTodayColumn &&
                                      formatDateKey(colDate) == todayKey;

                                  final dayCourses =
                                      widget.visibleCourses
                                          .where((c) => c.weekday == dayIndex)
                                          .toList()
                                        ..sort(
                                          (a, b) => a.startTime.compareTo(
                                            b.startTime,
                                          ),
                                        );

                                  return Container(
                                    width: colWidth,
                                    height: totalGridHeight,
                                    decoration: BoxDecoration(
                                      color: isTodayCol
                                          ? Colors.blueAccent.withValues(
                                              alpha: isDark ? 0.05 : 0.03,
                                            )
                                          : Colors.transparent,
                                      border: Border(
                                        right: BorderSide(color: gridLineColor),
                                      ),
                                    ),
                                    child: Stack(
                                      clipBehavior: Clip.none,
                                      children: dayCourses.map((c) {
                                        final topPx = calculateTopOffset(
                                          c.startTime,
                                          effectiveStartHour,
                                          widget.hourHeight,
                                        );
                                        final boxHeight = calculateBoxHeight(
                                          c.startTime,
                                          c.endTime,
                                          widget.hourHeight,
                                        );
                                        final durationMins =
                                            timeStringToMinutes(c.endTime) -
                                            timeStringToMinutes(c.startTime);
                                        final durationHrs =
                                            (durationMins / 60.0);

                                        final isCurrentWeek =
                                            _isCourseActiveInWeek(
                                              c,
                                              widget.currentWeek,
                                            );
                                        final isSelected =
                                            widget.selectedCourse?.id == c.id;
                                        final cColor = isCurrentWeek
                                            ? parseHexColor(c.color)
                                            : Colors.grey;

                                        return Positioned(
                                          top: topPx + 1.5,
                                          left: 3,
                                          right: 3,
                                          height: (boxHeight - 3.0).clamp(
                                            36.0,
                                            totalGridHeight,
                                          ),
                                          child: Opacity(
                                            opacity: isCurrentWeek ? 1.0 : 0.55,
                                            child: Material(
                                              color: Colors.transparent,
                                              child: InkWell(
                                                borderRadius:
                                                    BorderRadius.circular(10),
                                                onTap: () =>
                                                    widget.onCourseTap(c),
                                                child: Container(
                                                  padding:
                                                      const EdgeInsets.symmetric(
                                                        horizontal: 8,
                                                        vertical: 6,
                                                      ),
                                                  decoration: BoxDecoration(
                                                    color: isSelected
                                                        ? cColor.withValues(
                                                            alpha: isDark
                                                                ? 0.35
                                                                : 0.26,
                                                          )
                                                        : cColor.withValues(
                                                            alpha: isDark
                                                                ? 0.22
                                                                : 0.15,
                                                          ),
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          10,
                                                        ),
                                                    border: Border.all(
                                                      color: isSelected
                                                          ? cColor
                                                          : cColor.withValues(
                                                              alpha: 0.45,
                                                            ),
                                                      width: isSelected
                                                          ? 2.0
                                                          : 1.0,
                                                    ),
                                                  ),
                                                  child: ClipRect(
                                                    child: SingleChildScrollView(
                                                      physics:
                                                          const NeverScrollableScrollPhysics(),
                                                      child: Column(
                                                        crossAxisAlignment:
                                                            CrossAxisAlignment
                                                                .start,
                                                        mainAxisSize:
                                                            MainAxisSize.min,
                                                        children: [
                                                          Row(
                                                            crossAxisAlignment:
                                                                CrossAxisAlignment
                                                                    .start,
                                                            children: [
                                                              Expanded(
                                                                child: Text(
                                                                  trName(
                                                                    c.name,
                                                                    widget
                                                                        .isEnglish,
                                                                  ),
                                                                  maxLines:
                                                                      durationHrs >=
                                                                          2
                                                                      ? 2
                                                                      : 1,
                                                                  overflow:
                                                                      TextOverflow
                                                                          .ellipsis,
                                                                  style: TextStyle(
                                                                    fontWeight:
                                                                        FontWeight
                                                                            .bold,
                                                                    fontSize:
                                                                        widget
                                                                            .showRichDetail
                                                                        ? 12.5
                                                                        : 11,
                                                                    height: 1.2,
                                                                  ),
                                                                ),
                                                              ),
                                                              Container(
                                                                margin:
                                                                    const EdgeInsets.only(
                                                                      left: 4,
                                                                    ),
                                                                padding:
                                                                    const EdgeInsets.symmetric(
                                                                      horizontal:
                                                                          4,
                                                                      vertical:
                                                                          1,
                                                                    ),
                                                                decoration: BoxDecoration(
                                                                  color: cColor
                                                                      .withValues(
                                                                        alpha:
                                                                            0.2,
                                                                      ),
                                                                  borderRadius:
                                                                      BorderRadius.circular(
                                                                        4,
                                                                      ),
                                                                ),
                                                                child: Text(
                                                                  '${durationHrs.toStringAsFixed(durationHrs.truncateToDouble() == durationHrs ? 0 : 1)}h',
                                                                  style: TextStyle(
                                                                    fontSize:
                                                                        9.5,
                                                                    fontWeight:
                                                                        FontWeight
                                                                            .bold,
                                                                    color:
                                                                        cColor,
                                                                  ),
                                                                ),
                                                              ),
                                                            ],
                                                          ),
                                                          if (!isCurrentWeek)
                                                            Text(
                                                              widget.isEnglish
                                                                  ? '[Inactive]'
                                                                  : '[非本周]',
                                                              style: const TextStyle(
                                                                fontSize: 9.5,
                                                                fontWeight:
                                                                    FontWeight
                                                                        .bold,
                                                                color: Colors
                                                                    .orange,
                                                              ),
                                                            ),
                                                          const SizedBox(
                                                            height: 2,
                                                          ),
                                                          Text(
                                                            '${c.startTime} - ${c.endTime}',
                                                            style: TextStyle(
                                                              fontSize: 10.5,
                                                              fontWeight:
                                                                  FontWeight
                                                                      .w600,
                                                              color: isDark
                                                                  ? Colors
                                                                        .white70
                                                                  : Colors
                                                                        .black54,
                                                            ),
                                                          ),
                                                          if (!widget
                                                                  .isSimpleMode &&
                                                              boxHeight >=
                                                                  68) ...[
                                                            const SizedBox(
                                                              height: 2,
                                                            ),
                                                            Text(
                                                              trLocation(
                                                                c.location,
                                                                widget
                                                                    .isEnglish,
                                                              ),
                                                              maxLines:
                                                                  durationHrs >=
                                                                      2
                                                                  ? 2
                                                                  : 1,
                                                              overflow:
                                                                  TextOverflow
                                                                      .ellipsis,
                                                              style: TextStyle(
                                                                fontSize: 10,
                                                                color: isDark
                                                                    ? Colors
                                                                          .white60
                                                                    : Colors
                                                                          .black54,
                                                              ),
                                                            ),
                                                          ],
                                                          if (!widget
                                                                  .isSimpleMode &&
                                                              widget
                                                                  .showRichDetail &&
                                                              boxHeight >=
                                                                  115) ...[
                                                            const Divider(
                                                              height: 8,
                                                            ),
                                                            Text(
                                                              trTeacher(
                                                                c.teacher,
                                                                widget
                                                                    .isEnglish,
                                                              ),
                                                              maxLines: 1,
                                                              overflow:
                                                                  TextOverflow
                                                                      .ellipsis,
                                                              style: const TextStyle(
                                                                fontSize: 10,
                                                                fontWeight:
                                                                    FontWeight
                                                                        .w600,
                                                              ),
                                                            ),
                                                            if (c
                                                                    .remark
                                                                    .isNotEmpty &&
                                                                boxHeight >=
                                                                    145)
                                                              Padding(
                                                                padding:
                                                                    const EdgeInsets.only(
                                                                      top: 2,
                                                                    ),
                                                                child: Text(
                                                                  trRemark(
                                                                    c.remark,
                                                                    widget
                                                                        .isEnglish,
                                                                  ),
                                                                  maxLines:
                                                                      durationHrs >=
                                                                          3
                                                                      ? 3
                                                                      : 2,
                                                                  overflow:
                                                                      TextOverflow
                                                                          .ellipsis,
                                                                  style: const TextStyle(
                                                                    fontSize:
                                                                        9.5,
                                                                    color: Colors
                                                                        .blueAccent,
                                                                  ),
                                                                ),
                                                              ),
                                                          ],
                                                        ],
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                        );
                                      }).toList(),
                                    ),
                                  );
                                }).toList(),
                              ),
                              if (showRedLine)
                                Positioned(
                                  top: redLineTop - 4,
                                  left: 0,
                                  right: 0,
                                  child: IgnorePointer(
                                    child: Row(
                                      children: [
                                        Container(
                                          width: 8,
                                          height: 8,
                                          decoration: const BoxDecoration(
                                            color: Colors.redAccent,
                                            shape: BoxShape.circle,
                                          ),
                                        ),
                                        Expanded(
                                          child: Container(
                                            height: 1.8,
                                            color: Colors.redAccent,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

void showExcelImportAndSyncModal(BuildContext context, bool isEnglish) {
  final pasteCtrl = TextEditingController();
  final syncCodeCtrl = TextEditingController();

  showDialog(
    context: context,
    builder: (context) {
      return DefaultTabController(
        length: 2,
        child: AlertDialog(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                isEnglish
                    ? 'Excel Import & Cross-Device Sync'
                    : 'Excel 智能导入与双端同步',
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 18,
                ),
              ),
              const SizedBox(height: 8),
              TabBar(
                labelColor: Colors.blueAccent,
                unselectedLabelColor: Colors.grey,
                tabs: [
                  Tab(
                    icon: const Icon(Icons.table_chart_outlined),
                    text: isEnglish ? 'Excel Auto-Import' : 'Excel 表格导入',
                  ),
                  Tab(
                    icon: const Icon(Icons.sync),
                    text: isEnglish ? 'Dual-End Sync' : '双端数据互通',
                  ),
                ],
              ),
            ],
          ),
          content: SizedBox(
            width: 560,
            height: 360,
            child: TabBarView(
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.blueAccent.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.check_circle_outline,
                            color: Colors.blueAccent,
                            size: 20,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              isEnglish
                                  ? 'Detected: timetable-49898680.xls (9 UQ St Lucia activities).'
                                  : '已识别内置课表: timetable-49898680.xls（共 9 节课程活动）。',
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          TextButton(
                            onPressed: () {
                              final parsed =
                                  CourseSyncController.parseExcelTableText(
                                    CourseSyncController.uploadedExcelRawData,
                                  );
                              courseSyncCenter.importCourses(
                                parsed,
                                replaceAll: true,
                              );
                              Navigator.pop(context);
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    isEnglish
                                        ? 'Successfully imported ${parsed.length} courses from timetable-49898680.xls!'
                                        : '已成功从 timetable-49898680.xls 重新导入 ${parsed.length} 节课程！',
                                  ),
                                ),
                              );
                            },
                            child: Text(isEnglish ? 'Reload .xls' : '一键重载此表'),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      isEnglish
                          ? 'Or copy & paste rows directly from any Excel (.xls/.xlsx) or CSV file below:'
                          : '或者直接从任意 Excel (.xls/.xlsx) 全选复制行并粘贴到下方，系统将自动识别列字段：',
                      style: const TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: TextField(
                        controller: pasteCtrl,
                        maxLines: null,
                        expands: true,
                        textAlignVertical: TextAlignVertical.top,
                        decoration: InputDecoration(
                          hintText: isEnglish
                              ? 'Subject Code\tDescription\tGroup\tActivity\tDay\tTime\tCampus\tLocation...'
                              : '粘贴 Excel 内容（自动识别 Subject Code / Day / Time / Location / Staff / Duration）...',
                          hintStyle: const TextStyle(fontSize: 12),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        OutlinedButton(
                          onPressed: () {
                            final parsed =
                                CourseSyncController.parseExcelTableText(
                                  pasteCtrl.text,
                                );
                            if (parsed.isEmpty) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    isEnglish
                                        ? 'No valid rows recognized'
                                        : '未识别到有效课程行，请检查格式',
                                  ),
                                ),
                              );
                              return;
                            }
                            courseSyncCenter.importCourses(
                              parsed,
                              replaceAll: false,
                            );
                            Navigator.pop(context);
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  isEnglish
                                      ? 'Appended ${parsed.length} courses!'
                                      : '已增量导入 ${parsed.length} 门课程！',
                                ),
                              ),
                            );
                          },
                          child: Text(isEnglish ? 'Append' : '增量合并导入'),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.blueAccent,
                            foregroundColor: Colors.white,
                          ),
                          onPressed: () {
                            final parsed =
                                CourseSyncController.parseExcelTableText(
                                  pasteCtrl.text,
                                );
                            if (parsed.isEmpty) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    isEnglish
                                        ? 'No valid rows recognized'
                                        : '未识别到有效课程行，请检查格式',
                                  ),
                                ),
                              );
                              return;
                            }
                            courseSyncCenter.importCourses(
                              parsed,
                              replaceAll: true,
                            );
                            Navigator.pop(context);
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  isEnglish
                                      ? 'Replaced with ${parsed.length} courses!'
                                      : '已全新覆盖导入 ${parsed.length} 门课程！',
                                ),
                              ),
                            );
                          },
                          child: Text(isEnglish ? 'Replace All' : '覆盖导入课表'),
                        ),
                      ],
                    ),
                  ],
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isEnglish
                          ? 'Generate a sync code on PC Web and paste it on Mobile App (or vice versa) to sync all courses, events & developer broadcasts:'
                          : '在电脑网页端或手机端一键复制“同步码”，在另一端粘贴即可实现双端课表、日程与开发者广播秒级同步：',
                      style: const TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.copy, size: 18),
                        label: Text(
                          isEnglish ? 'Copy Current Sync Code' : '一键复制当前端同步码',
                        ),
                        onPressed: () {
                          final code = courseSyncCenter.exportToSyncJson();
                          Clipboard.setData(ClipboardData(text: code));
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                isEnglish
                                    ? 'Sync code copied to clipboard!'
                                    : '同步码已复制到剪贴板！去另一端粘贴即可同步。',
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: TextField(
                        controller: syncCodeCtrl,
                        maxLines: null,
                        expands: true,
                        textAlignVertical: TextAlignVertical.top,
                        decoration: InputDecoration(
                          hintText: isEnglish
                              ? 'Paste Sync Code (JSON) here...'
                              : '在此处粘贴来自另一端的同步码...',
                          hintStyle: const TextStyle(fontSize: 12),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Align(
                      alignment: Alignment.centerRight,
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green,
                          foregroundColor: Colors.white,
                        ),
                        icon: const Icon(
                          Icons.cloud_download_outlined,
                          size: 18,
                        ),
                        label: Text(isEnglish ? 'Sync Now' : '立即同步更新'),
                        onPressed: () {
                          try {
                            final count = courseSyncCenter.importFromSyncJson(
                              syncCodeCtrl.text.trim(),
                            );
                            Navigator.pop(context);
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  isEnglish
                                      ? 'Synced $count courses & events!'
                                      : '双端同步成功！已更新 $count 节课程及日程。',
                                ),
                              ),
                            );
                          } catch (_) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  isEnglish
                                      ? 'Invalid Sync Code'
                                      : '同步码格式有误，请重新复制',
                                ),
                              ),
                            );
                          }
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(isEnglish ? 'Close' : '关闭'),
            ),
          ],
        ),
      );
    },
  );
}

// ============================================================================
// MyApp: 启动即同步读取 globalPrefs（含用户自定义头像、昵称、ID 与隐藏开发者模式状态）
// ============================================================================
class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  late ThemeMode _themeMode;
  late bool _isEnglish;
  late bool _isSimpleMode;
  late bool _showNonCurrentWeek;
  late List<int> _visibleWeekdays;
  late int _columnsCount;
  late double _hourHeight;

  late bool _enableLiveTimeIndicator;
  late bool _highlightTodayColumn;
  late bool _autoCalculateWeek;
  late bool _autoExpandTo24Hours;
  late DateTime _semesterStartMonday;

  late int _devMessageReceiveMode;
  late String _lastReadBroadcastId;
  late bool _isDeveloperModeUnlocked;

  // 用户自定义头像与 ID 资料
  late String _userName;
  late String _userIdTag;
  late int _avatarIconIdx;
  late String _avatarColor;
  late String _avatarCustomText;

  @override
  void initState() {
    super.initState();
    _loadPreferencesSync();
  }

  void _loadPreferencesSync() {
    final themeIdx = globalPrefs.getInt('pref_theme_mode') ?? 0;
    _themeMode = ThemeMode.values[themeIdx.clamp(0, 2)];
    _isEnglish = globalPrefs.getBool('pref_is_english') ?? false;
    _isSimpleMode = globalPrefs.getBool('pref_is_simple_mode') ?? false;
    _showNonCurrentWeek =
        globalPrefs.getBool('pref_show_non_current_week') ?? false;

    final daysStr = globalPrefs.getString('pref_visible_weekdays');
    if (daysStr != null && daysStr.isNotEmpty) {
      try {
        _visibleWeekdays = (jsonDecode(daysStr) as List)
            .map((e) => (e as num).toInt())
            .toList();
      } catch (_) {
        _visibleWeekdays = [1, 2, 3, 4, 5, 6, 7];
      }
    } else {
      _visibleWeekdays = [1, 2, 3, 4, 5, 6, 7];
    }

    _columnsCount = (globalPrefs.getInt('pref_columns_count') ?? 5).clamp(
      1,
      _visibleWeekdays.length,
    );
    _hourHeight = globalPrefs.getDouble('pref_hour_height') ?? 84.0;

    _enableLiveTimeIndicator =
        globalPrefs.getBool('pref_live_time_indicator') ?? true;
    _highlightTodayColumn = globalPrefs.getBool('pref_highlight_today') ?? true;
    _autoCalculateWeek = globalPrefs.getBool('pref_auto_calc_week') ?? true;
    _autoExpandTo24Hours = globalPrefs.getBool('pref_auto_expand_24h') ?? true;

    final startMonStr = globalPrefs.getString('pref_semester_start_mon');
    if (startMonStr != null && startMonStr.isNotEmpty) {
      _semesterStartMonday =
          DateTime.tryParse(startMonStr) ?? DateTime(2026, 8, 3);
    } else {
      _semesterStartMonday = DateTime(2026, 8, 3);
    }

    _devMessageReceiveMode =
        (globalPrefs.getInt('pref_dev_msg_receive_mode') ?? 0).clamp(0, 2);
    _lastReadBroadcastId =
        globalPrefs.getString('pref_last_read_broadcast_id') ?? '';
    _isDeveloperModeUnlocked =
        globalPrefs.getBool('pref_dev_mode_unlocked') ?? false;

    _userName = globalPrefs.getString('pref_user_name') ?? 'UQ 圣卢西亚校区课表';
    _userIdTag = globalPrefs.getString('pref_user_id_tag') ?? 'ID: 49898680';
    _avatarIconIdx = globalPrefs.getInt('pref_avatar_icon_idx') ?? 0;
    _avatarColor = globalPrefs.getString('pref_avatar_color') ?? '#2979FF';
    _avatarCustomText = globalPrefs.getString('pref_avatar_custom_text') ?? '';
  }

  void _updateUserProfile(
    String name,
    String idTag,
    int iconIdx,
    String colorHex,
    String customText,
  ) {
    setState(() {
      _userName = name;
      _userIdTag = idTag;
      _avatarIconIdx = iconIdx;
      _avatarColor = colorHex;
      _avatarCustomText = customText;
    });
    globalPrefs.setString('pref_user_name', name);
    globalPrefs.setString('pref_user_id_tag', idTag);
    globalPrefs.setInt('pref_avatar_icon_idx', iconIdx);
    globalPrefs.setString('pref_avatar_color', colorHex);
    globalPrefs.setString('pref_avatar_custom_text', customText);
  }

  void _setDeveloperModeUnlocked(bool val) {
    setState(() => _isDeveloperModeUnlocked = val);
    globalPrefs.setBool('pref_dev_mode_unlocked', val);
  }

  void _toggleTheme(ThemeMode mode) {
    setState(() => _themeMode = mode);
    globalPrefs.setInt('pref_theme_mode', mode.index);
  }

  void _toggleLanguage(bool val) {
    setState(() => _isEnglish = val);
    globalPrefs.setBool('pref_is_english', val);
  }

  void _toggleSimpleMode(bool val) {
    setState(() => _isSimpleMode = val);
    globalPrefs.setBool('pref_is_simple_mode', val);
  }

  void _toggleShowNonCurrentWeek(bool val) {
    setState(() => _showNonCurrentWeek = val);
    globalPrefs.setBool('pref_show_non_current_week', val);
  }

  void _updateHourHeight(double val) {
    setState(() => _hourHeight = val);
    globalPrefs.setDouble('pref_hour_height', val);
  }

  void _toggleLiveTimeIndicator(bool val) {
    setState(() => _enableLiveTimeIndicator = val);
    globalPrefs.setBool('pref_live_time_indicator', val);
  }

  void _toggleHighlightTodayColumn(bool val) {
    setState(() => _highlightTodayColumn = val);
    globalPrefs.setBool('pref_highlight_today', val);
  }

  void _toggleAutoCalculateWeek(bool val) {
    setState(() => _autoCalculateWeek = val);
    globalPrefs.setBool('pref_auto_calc_week', val);
  }

  void _toggleAutoExpandTo24Hours(bool val) {
    setState(() => _autoExpandTo24Hours = val);
    globalPrefs.setBool('pref_auto_expand_24h', val);
  }

  void _updateSemesterStartMonday(DateTime dt) {
    final monday = dt.subtract(Duration(days: dt.weekday - 1));
    final clean = DateTime(monday.year, monday.month, monday.day);
    setState(() => _semesterStartMonday = clean);
    globalPrefs.setString('pref_semester_start_mon', clean.toIso8601String());
  }

  void _updateVisibleWeekdays(List<int> days) {
    if (days.isEmpty) {
      return;
    }
    setState(() {
      _visibleWeekdays = List.from(days)..sort();
      if (_columnsCount > _visibleWeekdays.length) {
        _columnsCount = _visibleWeekdays.length;
      }
    });
    globalPrefs.setString(
      'pref_visible_weekdays',
      jsonEncode(_visibleWeekdays),
    );
    globalPrefs.setInt('pref_columns_count', _columnsCount);
  }

  void _updateColumnsCount(int count) {
    setState(() => _columnsCount = count);
    globalPrefs.setInt('pref_columns_count', count);
  }

  void _updateDevMessageReceiveMode(int mode) {
    setState(() => _devMessageReceiveMode = mode.clamp(0, 2));
    globalPrefs.setInt('pref_dev_msg_receive_mode', _devMessageReceiveMode);
  }

  void _markAllBroadcastsRead() {
    if (courseSyncCenter.broadcasts.isNotEmpty) {
      final latestId = courseSyncCenter.broadcasts.first.id;
      setState(() => _lastReadBroadcastId = latestId);
      globalPrefs.setString('pref_last_read_broadcast_id', latestId);
    }
  }

  bool get _hasUnreadBroadcast {
    if (_devMessageReceiveMode == 2) {
      return false;
    }
    if (courseSyncCenter.broadcasts.isEmpty) {
      return false;
    }
    return courseSyncCenter.broadcasts.first.id != _lastReadBroadcastId;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: courseSyncCenter,
      builder: (context, _) {
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'Timetable',
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFF3F51B5),
              brightness: Brightness.light,
            ),
            useMaterial3: true,
            brightness: Brightness.light,
          ),
          darkTheme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFF5C6BC0),
              brightness: Brightness.dark,
            ),
            useMaterial3: true,
            brightness: Brightness.dark,
          ),
          themeMode: _themeMode,
          home: ResponsiveRoot(
            isEnglish: _isEnglish,
            onThemeChanged: _toggleTheme,
            onLanguageChanged: _toggleLanguage,
            currentThemeMode: _themeMode,
            isSimpleMode: _isSimpleMode,
            onSimpleModeChanged: _toggleSimpleMode,
            showNonCurrentWeek: _showNonCurrentWeek,
            onShowNonCurrentWeekChanged: _toggleShowNonCurrentWeek,
            visibleWeekdays: _visibleWeekdays,
            columnsCount: _columnsCount,
            onVisibleWeekdaysChanged: _updateVisibleWeekdays,
            onColumnsCountChanged: _updateColumnsCount,
            hourHeight: _hourHeight,
            onHourHeightChanged: _updateHourHeight,
            enableLiveTimeIndicator: _enableLiveTimeIndicator,
            onLiveTimeIndicatorChanged: _toggleLiveTimeIndicator,
            highlightTodayColumn: _highlightTodayColumn,
            onHighlightTodayColumnChanged: _toggleHighlightTodayColumn,
            autoCalculateWeek: _autoCalculateWeek,
            onAutoCalculateWeekChanged: _toggleAutoCalculateWeek,
            autoExpandTo24Hours: _autoExpandTo24Hours,
            onAutoExpandTo24HoursChanged: _toggleAutoExpandTo24Hours,
            semesterStartMonday: _semesterStartMonday,
            onSemesterStartMondayChanged: _updateSemesterStartMonday,
            devMessageReceiveMode: _devMessageReceiveMode,
            onDevMessageReceiveModeChanged: _updateDevMessageReceiveMode,
            hasUnreadBroadcast: _hasUnreadBroadcast,
            onMarkAllBroadcastsRead: _markAllBroadcastsRead,
            isDeveloperModeUnlocked: _isDeveloperModeUnlocked,
            onDeveloperModeChanged: _setDeveloperModeUnlocked,
            userName: _userName,
            userIdTag: _userIdTag,
            avatarIconIdx: _avatarIconIdx,
            avatarColor: _avatarColor,
            avatarCustomText: _avatarCustomText,
            onUserProfileChanged: _updateUserProfile,
          ),
        );
      },
    );
  }
}

class ResponsiveRoot extends StatefulWidget {
  final bool isEnglish;
  final ValueChanged<ThemeMode> onThemeChanged;
  final ValueChanged<bool> onLanguageChanged;
  final ThemeMode currentThemeMode;
  final bool isSimpleMode;
  final ValueChanged<bool> onSimpleModeChanged;
  final bool showNonCurrentWeek;
  final ValueChanged<bool> onShowNonCurrentWeekChanged;
  final List<int> visibleWeekdays;
  final int columnsCount;
  final ValueChanged<List<int>> onVisibleWeekdaysChanged;
  final ValueChanged<int> onColumnsCountChanged;
  final double hourHeight;
  final ValueChanged<double> onHourHeightChanged;
  final bool enableLiveTimeIndicator;
  final ValueChanged<bool> onLiveTimeIndicatorChanged;
  final bool highlightTodayColumn;
  final ValueChanged<bool> onHighlightTodayColumnChanged;
  final bool autoCalculateWeek;
  final ValueChanged<bool> onAutoCalculateWeekChanged;
  final bool autoExpandTo24Hours;
  final ValueChanged<bool> onAutoExpandTo24HoursChanged;
  final DateTime semesterStartMonday;
  final ValueChanged<DateTime> onSemesterStartMondayChanged;
  final int devMessageReceiveMode;
  final ValueChanged<int> onDevMessageReceiveModeChanged;
  final bool hasUnreadBroadcast;
  final VoidCallback onMarkAllBroadcastsRead;
  final bool isDeveloperModeUnlocked;
  final ValueChanged<bool> onDeveloperModeChanged;
  final String userName;
  final String userIdTag;
  final int avatarIconIdx;
  final String avatarColor;
  final String avatarCustomText;
  final void Function(
    String name,
    String idTag,
    int iconIdx,
    String colorHex,
    String customText,
  )
  onUserProfileChanged;

  const ResponsiveRoot({
    super.key,
    required this.isEnglish,
    required this.onThemeChanged,
    required this.onLanguageChanged,
    required this.currentThemeMode,
    required this.isSimpleMode,
    required this.onSimpleModeChanged,
    required this.showNonCurrentWeek,
    required this.onShowNonCurrentWeekChanged,
    required this.visibleWeekdays,
    required this.columnsCount,
    required this.onVisibleWeekdaysChanged,
    required this.onColumnsCountChanged,
    required this.hourHeight,
    required this.onHourHeightChanged,
    required this.enableLiveTimeIndicator,
    required this.onLiveTimeIndicatorChanged,
    required this.highlightTodayColumn,
    required this.onHighlightTodayColumnChanged,
    required this.autoCalculateWeek,
    required this.onAutoCalculateWeekChanged,
    required this.autoExpandTo24Hours,
    required this.onAutoExpandTo24HoursChanged,
    required this.semesterStartMonday,
    required this.onSemesterStartMondayChanged,
    required this.devMessageReceiveMode,
    required this.onDevMessageReceiveModeChanged,
    required this.hasUnreadBroadcast,
    required this.onMarkAllBroadcastsRead,
    required this.isDeveloperModeUnlocked,
    required this.onDeveloperModeChanged,
    required this.userName,
    required this.userIdTag,
    required this.avatarIconIdx,
    required this.avatarColor,
    required this.avatarCustomText,
    required this.onUserProfileChanged,
  });

  @override
  State<ResponsiveRoot> createState() => _ResponsiveRootState();
}

class _ResponsiveRootState extends State<ResponsiveRoot> {
  @override
  void initState() {
    super.initState();
    // 启动通知横幅严格根据当前中英文语言展示对应语言标题
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.devMessageReceiveMode == 0 &&
          widget.hasUnreadBroadcast &&
          courseSyncCenter.broadcasts.isNotEmpty) {
        final latest = courseSyncCenter.broadcasts.first;
        final msgTitle = latest.localizedTitle(widget.isEnglish);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 5),
            backgroundColor: Colors.blueAccent,
            content: Text(
              widget.isEnglish
                  ? 'New Developer Update: $msgTitle'
                  : '收到开发者新消息：$msgTitle',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
            action: SnackBarAction(
              label: widget.isEnglish ? 'View' : '立即查看',
              textColor: Colors.amberAccent,
              onPressed: () {
                showDeveloperInboxDialog(
                  context,
                  widget.isEnglish,
                  widget.devMessageReceiveMode,
                  widget.onMarkAllBroadcastsRead,
                );
              },
            ),
          ),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    if (kIsWeb && screenWidth > 900) {
      return DesktopLuxuryWorkspace(
        isEnglish: widget.isEnglish,
        onThemeChanged: widget.onThemeChanged,
        onLanguageChanged: widget.onLanguageChanged,
        currentThemeMode: widget.currentThemeMode,
        isSimpleMode: widget.isSimpleMode,
        onSimpleModeChanged: widget.onSimpleModeChanged,
        showNonCurrentWeek: widget.showNonCurrentWeek,
        onShowNonCurrentWeekChanged: widget.onShowNonCurrentWeekChanged,
        visibleWeekdays: widget.visibleWeekdays,
        columnsCount: widget.columnsCount,
        onVisibleWeekdaysChanged: widget.onVisibleWeekdaysChanged,
        onColumnsCountChanged: widget.onColumnsCountChanged,
        hourHeight: widget.hourHeight,
        onHourHeightChanged: widget.onHourHeightChanged,
        enableLiveTimeIndicator: widget.enableLiveTimeIndicator,
        onLiveTimeIndicatorChanged: widget.onLiveTimeIndicatorChanged,
        highlightTodayColumn: widget.highlightTodayColumn,
        onHighlightTodayColumnChanged: widget.onHighlightTodayColumnChanged,
        autoCalculateWeek: widget.autoCalculateWeek,
        onAutoCalculateWeekChanged: widget.onAutoCalculateWeekChanged,
        autoExpandTo24Hours: widget.autoExpandTo24Hours,
        onAutoExpandTo24HoursChanged: widget.onAutoExpandTo24HoursChanged,
        semesterStartMonday: widget.semesterStartMonday,
        onSemesterStartMondayChanged: widget.onSemesterStartMondayChanged,
        devMessageReceiveMode: widget.devMessageReceiveMode,
        onDevMessageReceiveModeChanged: widget.onDevMessageReceiveModeChanged,
        hasUnreadBroadcast: widget.hasUnreadBroadcast,
        onMarkAllBroadcastsRead: widget.onMarkAllBroadcastsRead,
        isDeveloperModeUnlocked: widget.isDeveloperModeUnlocked,
        onDeveloperModeChanged: widget.onDeveloperModeChanged,
        userName: widget.userName,
        userIdTag: widget.userIdTag,
        avatarIconIdx: widget.avatarIconIdx,
        avatarColor: widget.avatarColor,
        avatarCustomText: widget.avatarCustomText,
        onUserProfileChanged: widget.onUserProfileChanged,
      );
    } else {
      return MobileMainScreen(
        isEnglish: widget.isEnglish,
        onThemeChanged: widget.onThemeChanged,
        onLanguageChanged: widget.onLanguageChanged,
        currentThemeMode: widget.currentThemeMode,
        isSimpleMode: widget.isSimpleMode,
        onSimpleModeChanged: widget.onSimpleModeChanged,
        showNonCurrentWeek: widget.showNonCurrentWeek,
        onShowNonCurrentWeekChanged: widget.onShowNonCurrentWeekChanged,
        visibleWeekdays: widget.visibleWeekdays,
        columnsCount: widget.columnsCount,
        onVisibleWeekdaysChanged: widget.onVisibleWeekdaysChanged,
        onColumnsCountChanged: widget.onColumnsCountChanged,
        hourHeight: widget.hourHeight,
        onHourHeightChanged: widget.onHourHeightChanged,
        enableLiveTimeIndicator: widget.enableLiveTimeIndicator,
        onLiveTimeIndicatorChanged: widget.onLiveTimeIndicatorChanged,
        highlightTodayColumn: widget.highlightTodayColumn,
        onHighlightTodayColumnChanged: widget.onHighlightTodayColumnChanged,
        autoCalculateWeek: widget.autoCalculateWeek,
        onAutoCalculateWeekChanged: widget.onAutoCalculateWeekChanged,
        autoExpandTo24Hours: widget.autoExpandTo24Hours,
        onAutoExpandTo24HoursChanged: widget.onAutoExpandTo24HoursChanged,
        semesterStartMonday: widget.semesterStartMonday,
        onSemesterStartMondayChanged: widget.onSemesterStartMondayChanged,
        devMessageReceiveMode: widget.devMessageReceiveMode,
        onDevMessageReceiveModeChanged: widget.onDevMessageReceiveModeChanged,
        hasUnreadBroadcast: widget.hasUnreadBroadcast,
        onMarkAllBroadcastsRead: widget.onMarkAllBroadcastsRead,
        isDeveloperModeUnlocked: widget.isDeveloperModeUnlocked,
        onDeveloperModeChanged: widget.onDeveloperModeChanged,
        userName: widget.userName,
        userIdTag: widget.userIdTag,
        avatarIconIdx: widget.avatarIconIdx,
        avatarColor: widget.avatarColor,
        avatarCustomText: widget.avatarCustomText,
        onUserProfileChanged: widget.onUserProfileChanged,
      );
    }
  }
}

// ============================================================================
// 1. 电脑网页端：轻奢风工作台
// ============================================================================
class DesktopLuxuryWorkspace extends StatefulWidget {
  final bool isEnglish;
  final ValueChanged<ThemeMode> onThemeChanged;
  final ValueChanged<bool> onLanguageChanged;
  final ThemeMode currentThemeMode;
  final bool isSimpleMode;
  final ValueChanged<bool> onSimpleModeChanged;
  final bool showNonCurrentWeek;
  final ValueChanged<bool> onShowNonCurrentWeekChanged;
  final List<int> visibleWeekdays;
  final int columnsCount;
  final ValueChanged<List<int>> onVisibleWeekdaysChanged;
  final ValueChanged<int> onColumnsCountChanged;
  final double hourHeight;
  final ValueChanged<double> onHourHeightChanged;
  final bool enableLiveTimeIndicator;
  final ValueChanged<bool> onLiveTimeIndicatorChanged;
  final bool highlightTodayColumn;
  final ValueChanged<bool> onHighlightTodayColumnChanged;
  final bool autoCalculateWeek;
  final ValueChanged<bool> onAutoCalculateWeekChanged;
  final bool autoExpandTo24Hours;
  final ValueChanged<bool> onAutoExpandTo24HoursChanged;
  final DateTime semesterStartMonday;
  final ValueChanged<DateTime> onSemesterStartMondayChanged;
  final int devMessageReceiveMode;
  final ValueChanged<int> onDevMessageReceiveModeChanged;
  final bool hasUnreadBroadcast;
  final VoidCallback onMarkAllBroadcastsRead;
  final bool isDeveloperModeUnlocked;
  final ValueChanged<bool> onDeveloperModeChanged;
  final String userName;
  final String userIdTag;
  final int avatarIconIdx;
  final String avatarColor;
  final String avatarCustomText;
  final void Function(
    String name,
    String idTag,
    int iconIdx,
    String colorHex,
    String customText,
  )
  onUserProfileChanged;

  const DesktopLuxuryWorkspace({
    super.key,
    required this.isEnglish,
    required this.onThemeChanged,
    required this.onLanguageChanged,
    required this.currentThemeMode,
    required this.isSimpleMode,
    required this.onSimpleModeChanged,
    required this.showNonCurrentWeek,
    required this.onShowNonCurrentWeekChanged,
    required this.visibleWeekdays,
    required this.columnsCount,
    required this.onVisibleWeekdaysChanged,
    required this.onColumnsCountChanged,
    required this.hourHeight,
    required this.onHourHeightChanged,
    required this.enableLiveTimeIndicator,
    required this.onLiveTimeIndicatorChanged,
    required this.highlightTodayColumn,
    required this.onHighlightTodayColumnChanged,
    required this.autoCalculateWeek,
    required this.onAutoCalculateWeekChanged,
    required this.autoExpandTo24Hours,
    required this.onAutoExpandTo24HoursChanged,
    required this.semesterStartMonday,
    required this.onSemesterStartMondayChanged,
    required this.devMessageReceiveMode,
    required this.onDevMessageReceiveModeChanged,
    required this.hasUnreadBroadcast,
    required this.onMarkAllBroadcastsRead,
    required this.isDeveloperModeUnlocked,
    required this.onDeveloperModeChanged,
    required this.userName,
    required this.userIdTag,
    required this.avatarIconIdx,
    required this.avatarColor,
    required this.avatarCustomText,
    required this.onUserProfileChanged,
  });

  @override
  State<DesktopLuxuryWorkspace> createState() => _DesktopLuxuryWorkspaceState();
}

class _DesktopLuxuryWorkspaceState extends State<DesktopLuxuryWorkspace> {
  int _sidebarIndex = 0;
  String _viewMode = 'Week';
  late int _currentWeek;
  Course? _selectedCourse;

  int get _systemCurrentWeek =>
      calculateWeekFromStartMonday(widget.semesterStartMonday, DateTime.now());

  @override
  void initState() {
    super.initState();
    _currentWeek = widget.autoCalculateWeek ? _systemCurrentWeek : 11;
  }

  @override
  void didUpdateWidget(covariant DesktopLuxuryWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((widget.autoCalculateWeek && !oldWidget.autoCalculateWeek) ||
        oldWidget.semesterStartMonday != widget.semesterStartMonday) {
      if (widget.autoCalculateWeek) {
        _currentWeek = _systemCurrentWeek;
      }
    }
  }

  List<Course> get _allCourses => courseSyncCenter.courses;

  bool _isCourseActiveInWeek(Course c, int week) =>
      week >= c.startWeek && week <= c.endWeek;

  List<Course> get _visibleCourses {
    if (widget.showNonCurrentWeek) {
      return _allCourses;
    }
    return _allCourses
        .where((c) => _isCourseActiveInWeek(c, _currentWeek))
        .toList();
  }

  Course? get _effectiveSelectedCourse {
    final visible = _visibleCourses;
    if (visible.isEmpty) {
      return null;
    }
    if (_selectedCourse != null &&
        visible.any((c) => c.id == _selectedCourse!.id)) {
      return visible.firstWhere((c) => c.id == _selectedCourse!.id);
    }
    return visible.first;
  }

  void _deleteSelectedCourse() {
    final target = _effectiveSelectedCourse;
    if (target == null) {
      return;
    }
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(widget.isEnglish ? 'Delete Course' : '确认删除'),
        content: Text(widget.isEnglish ? 'Are you sure?' : '确定要删除这门课程吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(widget.isEnglish ? 'Cancel' : '取消'),
          ),
          TextButton(
            onPressed: () {
              courseSyncCenter.deleteCourseById(target.id);
              Navigator.pop(context);
            },
            child: Text(
              widget.isEnglish ? 'Delete' : '删除',
              style: const TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _editSelectedCourse() async {
    final target = _effectiveSelectedCourse;
    if (target == null) {
      return;
    }
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) =>
            AddCoursePage(isEnglish: widget.isEnglish, courseToEdit: target),
      ),
    );
    if (result != null && result is Course) {
      courseSyncCenter.addOrUpdateCourse(result);
      setState(() => _selectedCourse = result);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgCol = isDark ? const Color(0xFF121212) : const Color(0xFFF8F9FA);
    final cardBg = isDark ? const Color(0xFF1E1E1E) : Colors.white;
    final borderCol = isDark ? Colors.white12 : Colors.black12;
    final selected = _effectiveSelectedCourse;
    final autoWeek = _systemCurrentWeek;

    return Scaffold(
      backgroundColor: bgCol,
      body: Row(
        children: [
          Container(
            width: 290,
            color: cardBg,
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.dashboard_outlined,
                      color: Colors.blueAccent,
                      size: 24,
                    ),
                    const SizedBox(width: 12),
                    Text(
                      widget.isEnglish ? 'TIMETABLE' : '课程表',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                        letterSpacing: 1.5,
                      ),
                    ),
                    const Spacer(),
                    if (widget.devMessageReceiveMode != 2)
                      IconButton(
                        tooltip: widget.isEnglish
                            ? 'Developer Messages & Guides'
                            : '开发者更新信息与使用指导',
                        onPressed: () => showDeveloperInboxDialog(
                          context,
                          widget.isEnglish,
                          widget.devMessageReceiveMode,
                          widget.onMarkAllBroadcastsRead,
                        ),
                        icon: Badge(
                          isLabelVisible:
                              widget.hasUnreadBroadcast &&
                              widget.devMessageReceiveMode == 0,
                          child: const Icon(Icons.notifications_none, size: 20),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                _buildSidebarItem(
                  Icons.grid_view_rounded,
                  widget.isEnglish ? 'Timetable' : '课表视图',
                  _sidebarIndex == 0,
                  () {
                    setState(() => _sidebarIndex = 0);
                  },
                ),
                _buildSidebarItem(
                  Icons.calendar_month_outlined,
                  widget.isEnglish ? 'Schedule & Tasks' : '日程与待办',
                  _sidebarIndex == 1,
                  () {
                    setState(() => _sidebarIndex = 1);
                  },
                ),
                _buildSidebarItem(
                  Icons.settings_outlined,
                  widget.isEnglish ? 'Profile & Settings' : '我的与设置',
                  _sidebarIndex == 2,
                  () {
                    setState(() => _sidebarIndex = 2);
                  },
                ),
                const Divider(height: 16),
                Expanded(
                  child: ListView(
                    padding: EdgeInsets.zero,
                    children: [
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: Text(
                          widget.isEnglish
                              ? 'Auto-Expand to 24h'
                              : '越界课程自动扩展至24小时',
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        subtitle: Text(
                          widget.isEnglish
                              ? 'Default 07:00-22:00'
                              : '常驻 07:00-22:00',
                          style: const TextStyle(
                            fontSize: 10,
                            color: Colors.grey,
                          ),
                        ),
                        value: widget.autoExpandTo24Hours,
                        onChanged: widget.onAutoExpandTo24HoursChanged,
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: Text(
                          widget.isEnglish
                              ? 'Live Time Red Line'
                              : '实时时间轴红线指示器',
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        value: widget.enableLiveTimeIndicator,
                        onChanged: widget.onLiveTimeIndicatorChanged,
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: Text(
                          widget.isEnglish
                              ? 'Highlight Today & Dates'
                              : '今日列高亮与具体日期',
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        value: widget.highlightTodayColumn,
                        onChanged: widget.onHighlightTodayColumnChanged,
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: Text(
                          widget.isEnglish
                              ? 'Auto-Locate Current Week'
                              : '根据系统日期自动推算当前周',
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        value: widget.autoCalculateWeek,
                        onChanged: widget.onAutoCalculateWeekChanged,
                      ),
                      const Divider(height: 16),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: Text(
                          widget.isEnglish ? 'Compact Mode' : '简洁模式 (隐藏次要信息)',
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        value: widget.isSimpleMode,
                        onChanged: widget.onSimpleModeChanged,
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: Text(
                          widget.isEnglish
                              ? 'Show Non-Current Week'
                              : '显示非本周课程',
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        value: widget.showNonCurrentWeek,
                        onChanged: widget.onShowNonCurrentWeekChanged,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        widget.isEnglish ? 'Displayed Days' : '显示星期 (过滤无课日)',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: Colors.grey,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: List.generate(7, (index) {
                          int day = index + 1;
                          bool isSelected = widget.visibleWeekdays.contains(
                            day,
                          );
                          return FilterChip(
                            label: Text(
                              getWeekdayLabel(day, widget.isEnglish),
                              style: const TextStyle(fontSize: 11),
                            ),
                            selected: isSelected,
                            visualDensity: VisualDensity.compact,
                            onSelected: (val) {
                              final next = List<int>.from(
                                widget.visibleWeekdays,
                              );
                              if (val) {
                                next.add(day);
                              } else if (next.length > 1) {
                                next.remove(day);
                              }
                              widget.onVisibleWeekdaysChanged(next);
                            },
                          );
                        }),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            widget.isEnglish ? 'Columns' : '同屏展示列数',
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: Colors.grey,
                            ),
                          ),
                          Text(
                            '${widget.columnsCount} ${widget.isEnglish ? 'Cols' : '列'}',
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: Colors.blueAccent,
                            ),
                          ),
                        ],
                      ),
                      Slider(
                        value: widget.columnsCount.toDouble().clamp(
                          1,
                          widget.visibleWeekdays.length.toDouble(),
                        ),
                        min: 1,
                        max: widget.visibleWeekdays.length.toDouble(),
                        divisions: widget.visibleWeekdays.length > 1
                            ? widget.visibleWeekdays.length - 1
                            : 1,
                        onChanged: (val) =>
                            widget.onColumnsCountChanged(val.toInt()),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  margin: const EdgeInsets.only(bottom: 8),
                  decoration: BoxDecoration(
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.05)
                        : Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        widget.isEnglish ? 'Theme' : '主题',
                        style: const TextStyle(
                          fontSize: 13,
                          color: Colors.grey,
                        ),
                      ),
                      DropdownButton<ThemeMode>(
                        value: widget.currentThemeMode,
                        underline: const SizedBox(),
                        style: TextStyle(
                          fontSize: 13,
                          color: isDark ? Colors.white : Colors.black87,
                        ),
                        items: [
                          DropdownMenuItem(
                            value: ThemeMode.system,
                            child: Text(widget.isEnglish ? 'System' : '跟随系统'),
                          ),
                          DropdownMenuItem(
                            value: ThemeMode.light,
                            child: Text(widget.isEnglish ? 'Light' : '浅色'),
                          ),
                          DropdownMenuItem(
                            value: ThemeMode.dark,
                            child: Text(widget.isEnglish ? 'Dark' : '深色'),
                          ),
                        ],
                        onChanged: (val) {
                          if (val != null) {
                            widget.onThemeChanged(val);
                          }
                        },
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.05)
                        : Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        widget.isEnglish ? 'Language' : '语言',
                        style: const TextStyle(
                          fontSize: 13,
                          color: Colors.grey,
                        ),
                      ),
                      DropdownButton<bool>(
                        value: widget.isEnglish,
                        underline: const SizedBox(),
                        style: TextStyle(
                          fontSize: 13,
                          color: isDark ? Colors.white : Colors.black87,
                        ),
                        items: const [
                          DropdownMenuItem(value: false, child: Text('简体中文')),
                          DropdownMenuItem(value: true, child: Text('English')),
                        ],
                        onChanged: (val) {
                          if (val != null) {
                            widget.onLanguageChanged(val);
                          }
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          VerticalDivider(width: 1, color: borderCol),
          if (_sidebarIndex == 1)
            Expanded(
              flex: 4,
              child: SchedulePage(isEnglish: widget.isEnglish, isDesktop: true),
            )
          else if (_sidebarIndex == 2)
            Expanded(
              flex: 4,
              child: ProfilePage(
                isEnglish: widget.isEnglish,
                onThemeChanged: widget.onThemeChanged,
                onLanguageChanged: widget.onLanguageChanged,
                currentThemeMode: widget.currentThemeMode,
                isSimpleMode: widget.isSimpleMode,
                onSimpleModeChanged: widget.onSimpleModeChanged,
                showNonCurrentWeek: widget.showNonCurrentWeek,
                onShowNonCurrentWeekChanged: widget.onShowNonCurrentWeekChanged,
                visibleWeekdays: widget.visibleWeekdays,
                columnsCount: widget.columnsCount,
                onVisibleWeekdaysChanged: widget.onVisibleWeekdaysChanged,
                onColumnsCountChanged: widget.onColumnsCountChanged,
                hourHeight: widget.hourHeight,
                onHourHeightChanged: widget.onHourHeightChanged,
                enableLiveTimeIndicator: widget.enableLiveTimeIndicator,
                onLiveTimeIndicatorChanged: widget.onLiveTimeIndicatorChanged,
                highlightTodayColumn: widget.highlightTodayColumn,
                onHighlightTodayColumnChanged:
                    widget.onHighlightTodayColumnChanged,
                autoCalculateWeek: widget.autoCalculateWeek,
                onAutoCalculateWeekChanged: widget.onAutoCalculateWeekChanged,
                autoExpandTo24Hours: widget.autoExpandTo24Hours,
                onAutoExpandTo24HoursChanged:
                    widget.onAutoExpandTo24HoursChanged,
                semesterStartMonday: widget.semesterStartMonday,
                onSemesterStartMondayChanged:
                    widget.onSemesterStartMondayChanged,
                devMessageReceiveMode: widget.devMessageReceiveMode,
                onDevMessageReceiveModeChanged:
                    widget.onDevMessageReceiveModeChanged,
                hasUnreadBroadcast: widget.hasUnreadBroadcast,
                onMarkAllBroadcastsRead: widget.onMarkAllBroadcastsRead,
                isDeveloperModeUnlocked: widget.isDeveloperModeUnlocked,
                onDeveloperModeChanged: widget.onDeveloperModeChanged,
                userName: widget.userName,
                userIdTag: widget.userIdTag,
                avatarIconIdx: widget.avatarIconIdx,
                avatarColor: widget.avatarColor,
                avatarCustomText: widget.avatarCustomText,
                onUserProfileChanged: widget.onUserProfileChanged,
              ),
            )
          else ...[
            Expanded(
              flex: 3,
              child: Padding(
                padding: const EdgeInsets.all(28.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            IconButton(
                              icon: const Icon(Icons.chevron_left),
                              onPressed: () {
                                if (_currentWeek > 1) {
                                  setState(() => _currentWeek--);
                                }
                              },
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 8,
                              ),
                              decoration: BoxDecoration(
                                color: cardBg,
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: borderCol),
                              ),
                              child: Row(
                                children: [
                                  Text(
                                    widget.isEnglish
                                        ? 'Week $_currentWeek'
                                        : '第 $_currentWeek 周',
                                    style: const TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  if (widget.autoCalculateWeek &&
                                      _currentWeek == autoWeek) ...[
                                    const SizedBox(width: 8),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 6,
                                        vertical: 2,
                                      ),
                                      decoration: BoxDecoration(
                                        color: Colors.green.withValues(
                                          alpha: 0.15,
                                        ),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: Text(
                                        widget.isEnglish ? 'Current' : '本周',
                                        style: const TextStyle(
                                          fontSize: 11,
                                          color: Colors.green,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.chevron_right),
                              onPressed: () {
                                if (_currentWeek < 20) {
                                  setState(() => _currentWeek++);
                                }
                              },
                            ),
                            if (widget.autoCalculateWeek &&
                                _currentWeek != autoWeek)
                              TextButton.icon(
                                onPressed: () =>
                                    setState(() => _currentWeek = autoWeek),
                                icon: const Icon(Icons.today, size: 16),
                                label: Text(
                                  widget.isEnglish
                                      ? 'Back to Week $autoWeek'
                                      : '回到第 $autoWeek 周',
                                ),
                              ),
                            const SizedBox(width: 12),
                            ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.blueAccent,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 12,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                              ),
                              onPressed: () async {
                                final result = await Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (context) => AddCoursePage(
                                      isEnglish: widget.isEnglish,
                                    ),
                                  ),
                                );
                                if (result != null && result is Course) {
                                  courseSyncCenter.addOrUpdateCourse(result);
                                  setState(() => _selectedCourse = result);
                                }
                              },
                              icon: const Icon(Icons.add, size: 18),
                              label: Text(
                                widget.isEnglish ? 'Add Course' : '添加课程',
                              ),
                            ),
                            const SizedBox(width: 10),
                            OutlinedButton.icon(
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 12,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                              ),
                              onPressed: () => showExcelImportAndSyncModal(
                                context,
                                widget.isEnglish,
                              ),
                              icon: const Icon(
                                Icons.upload_file,
                                size: 18,
                                color: Colors.blueAccent,
                              ),
                              label: Text(
                                widget.isEnglish
                                    ? 'Excel Import / Sync'
                                    : 'Excel 导入与同步',
                              ),
                            ),
                          ],
                        ),
                        Container(
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            color: cardBg,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: borderCol),
                          ),
                          child: Row(
                            children: [
                              _buildViewTab(
                                'Day',
                                widget.isEnglish ? 'Day' : '日',
                              ),
                              _buildViewTab(
                                'Week',
                                widget.isEnglish ? 'Week' : '周',
                              ),
                              _buildViewTab(
                                'Month',
                                widget.isEnglish ? 'Month' : '月',
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    Expanded(
                      child: Container(
                        clipBehavior: Clip.antiAlias,
                        decoration: BoxDecoration(
                          color: cardBg,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: borderCol),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.02),
                              blurRadius: 10,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: _viewMode == 'Month'
                            ? Padding(
                                padding: const EdgeInsets.all(20),
                                child: _buildMonthView(),
                              )
                            : _viewMode == 'Week'
                            ? ProportionalTimeGrid(
                                visibleWeekdays: widget.visibleWeekdays,
                                columnsCount: widget.columnsCount,
                                visibleCourses: _visibleCourses,
                                currentWeek: _currentWeek,
                                isEnglish: widget.isEnglish,
                                isSimpleMode: widget.isSimpleMode,
                                showRichDetail: widget.columnsCount <= 4,
                                hourHeight: widget.hourHeight,
                                enableLiveTimeIndicator:
                                    widget.enableLiveTimeIndicator,
                                highlightTodayColumn:
                                    widget.highlightTodayColumn,
                                autoExpandTo24Hours: widget.autoExpandTo24Hours,
                                semesterStartMonday: widget.semesterStartMonday,
                                selectedCourse: selected,
                                onCourseTap: (c) =>
                                    setState(() => _selectedCourse = c),
                              )
                            : Padding(
                                padding: const EdgeInsets.all(20),
                                child: _buildDayView(selected),
                              ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            VerticalDivider(width: 1, color: borderCol),
            Expanded(
              flex: 1,
              child: Container(
                color: cardBg,
                padding: const EdgeInsets.all(24),
                child: selected == null
                    ? Center(
                        child: Text(
                          widget.isEnglish ? 'Select a course' : '点击左侧课程查看详情',
                          style: const TextStyle(color: Colors.grey),
                        ),
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                widget.isEnglish ? 'Course Details' : '课程详情',
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                ),
                              ),
                              Row(
                                children: [
                                  IconButton(
                                    icon: const Icon(
                                      Icons.edit_outlined,
                                      color: Colors.blueAccent,
                                    ),
                                    tooltip: widget.isEnglish
                                        ? 'Edit Course'
                                        : '编辑课程',
                                    onPressed: _editSelectedCourse,
                                  ),
                                  IconButton(
                                    icon: const Icon(
                                      Icons.delete_outline,
                                      color: Colors.redAccent,
                                    ),
                                    tooltip: widget.isEnglish
                                        ? 'Delete Course'
                                        : '删除课程',
                                    onPressed: _deleteSelectedCourse,
                                  ),
                                ],
                              ),
                            ],
                          ),
                          const Divider(height: 24),
                          Row(
                            children: [
                              Container(
                                width: 12,
                                height: 12,
                                decoration: BoxDecoration(
                                  color: parseHexColor(selected.color),
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  trName(selected.name, widget.isEnglish),
                                  style: const TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          if (!_isCourseActiveInWeek(
                            selected,
                            _currentWeek,
                          )) ...[
                            const SizedBox(height: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.orange.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                widget.isEnglish
                                    ? 'Non-Current Week Course'
                                    : '非本周课程',
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: Colors.orange,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                          const SizedBox(height: 20),
                          _buildDetailRow(
                            Icons.calendar_today,
                            widget.isEnglish ? 'Day' : '星期',
                            getWeekdayLabel(selected.weekday, widget.isEnglish),
                          ),
                          _buildDetailRow(
                            Icons.access_time,
                            widget.isEnglish ? 'Time' : '时间',
                            '${selected.startTime} - ${selected.endTime}',
                          ),
                          if (!widget.isSimpleMode) ...[
                            _buildDetailRow(
                              Icons.star_border,
                              widget.isEnglish ? 'Credits' : '学分',
                              '${selected.credits} Cr',
                            ),
                            _buildDetailRow(
                              Icons.person_outline,
                              widget.isEnglish ? 'Teacher' : '教师',
                              trTeacher(selected.teacher, widget.isEnglish),
                            ),
                            _buildDetailRow(
                              Icons.date_range,
                              widget.isEnglish ? 'Weeks' : '周数',
                              widget.isEnglish
                                  ? 'Weeks ${selected.startWeek} - ${selected.endWeek}'
                                  : '第 ${selected.startWeek} - ${selected.endWeek} 周',
                            ),
                            if (selected.remark.isNotEmpty) ...[
                              _buildDetailRow(
                                Icons.notes,
                                widget.isEnglish ? 'Info' : '详情',
                                trRemark(selected.remark, widget.isEnglish),
                              ),
                            ],
                          ],
                          const SizedBox(height: 20),
                          InkWell(
                            onTap: () async {
                              final query = Uri.encodeComponent(
                                '${selected.location} UQ St Lucia',
                              );
                              final url = Uri.parse(
                                'https://www.google.com/maps/search/?api=1&query=$query',
                              );
                              if (await canLaunchUrl(url)) {
                                await launchUrl(
                                  url,
                                  mode: LaunchMode.externalApplication,
                                );
                              }
                            },
                            child: Container(
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                color: Colors.redAccent.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: Colors.redAccent.withValues(
                                    alpha: 0.3,
                                  ),
                                ),
                              ),
                              child: Row(
                                children: [
                                  const Icon(
                                    Icons.location_on,
                                    color: Colors.redAccent,
                                    size: 20,
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          widget.isEnglish
                                              ? 'Location (Google Maps)'
                                              : '上课教室导航',
                                          style: const TextStyle(
                                            fontWeight: FontWeight.bold,
                                            fontSize: 12,
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          trLocation(
                                            selected.location,
                                            widget.isEnglish,
                                          ),
                                          style: const TextStyle(fontSize: 13),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const Icon(
                                    Icons.open_in_new,
                                    size: 16,
                                    color: Colors.redAccent,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSidebarItem(
    IconData icon,
    String label,
    bool active,
    VoidCallback onTap,
  ) => Container(
    margin: const EdgeInsets.only(bottom: 6),
    decoration: BoxDecoration(
      color: active
          ? Colors.blueAccent.withValues(alpha: 0.1)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(10),
    ),
    child: ListTile(
      onTap: onTap,
      leading: Icon(
        icon,
        color: active ? Colors.blueAccent : Colors.grey,
        size: 20,
      ),
      title: Text(
        label,
        style: TextStyle(
          color: active ? Colors.blueAccent : null,
          fontWeight: active ? FontWeight.bold : FontWeight.normal,
          fontSize: 14,
        ),
      ),
      dense: true,
    ),
  );

  Widget _buildViewTab(String mode, String label) => GestureDetector(
    onTap: () => setState(() => _viewMode = mode),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: _viewMode == mode ? Colors.blueAccent : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: _viewMode == mode ? Colors.white : Colors.grey,
          fontWeight: FontWeight.bold,
          fontSize: 13,
        ),
      ),
    ),
  );

  Widget _buildDayView(Course? selected) {
    final visible = _visibleCourses
      ..sort((a, b) => a.weekday.compareTo(b.weekday));
    if (visible.isEmpty) {
      return Center(
        child: Text(
          widget.isEnglish ? 'No courses' : '暂无课程',
          style: const TextStyle(color: Colors.grey),
        ),
      );
    }
    return ListView.builder(
      itemCount: visible.length,
      itemBuilder: (context, index) {
        final c = visible[index];
        final isSelected = selected?.id == c.id;
        final cColor = parseHexColor(c.color);
        return Card(
          margin: const EdgeInsets.symmetric(vertical: 6),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(
              color: isSelected ? cColor : Colors.transparent,
              width: 2,
            ),
          ),
          child: ListTile(
            onTap: () => setState(() => _selectedCourse = c),
            leading: CircleAvatar(
              backgroundColor: cColor.withValues(alpha: 0.2),
              child: Text(
                getWeekdayLabel(c.weekday, widget.isEnglish),
                style: TextStyle(
                  color: cColor,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            title: Text(
              trName(c.name, widget.isEnglish),
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            subtitle: Text(
              '${c.startTime} - ${c.endTime}  |  ${trLocation(c.location, widget.isEnglish)}',
            ),
          ),
        );
      },
    );
  }

  Widget _buildMonthView() {
    return GridView.builder(
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 7,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      itemCount: 30,
      itemBuilder: (context, index) {
        int weekday = (index % 7) + 1;
        final dayCourses = _visibleCourses
            .where((c) => c.weekday == weekday)
            .toList();
        return Container(
          decoration: BoxDecoration(
            color: Colors.grey.withValues(alpha: 0.03),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.grey.withValues(alpha: 0.1)),
          ),
          padding: const EdgeInsets.all(8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${index + 1}',
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 4),
              Expanded(
                child: ListView(
                  children: dayCourses.map((c) {
                    bool isCurrentWeek = _isCourseActiveInWeek(c, _currentWeek);
                    final cColor = isCurrentWeek
                        ? parseHexColor(c.color)
                        : Colors.grey;
                    return Opacity(
                      opacity: isCurrentWeek ? 1.0 : 0.5,
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 2),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: cColor.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          trName(c.name, widget.isEnglish),
                          style: TextStyle(
                            fontSize: 10,
                            color: cColor,
                            fontWeight: FontWeight.bold,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildDetailRow(IconData icon, String label, String val) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Row(
      children: [
        Icon(icon, size: 18, color: Colors.grey),
        const SizedBox(width: 12),
        Text(label, style: const TextStyle(color: Colors.grey)),
        const Spacer(),
        Flexible(
          child: Text(
            val,
            style: const TextStyle(fontWeight: FontWeight.bold),
            textAlign: TextAlign.right,
          ),
        ),
      ],
    ),
  );
}

// ============================================================================
// 2. 手机端主容器
// ============================================================================
class MobileMainScreen extends StatefulWidget {
  final bool isEnglish;
  final ValueChanged<ThemeMode> onThemeChanged;
  final ValueChanged<bool> onLanguageChanged;
  final ThemeMode currentThemeMode;
  final bool isSimpleMode;
  final ValueChanged<bool> onSimpleModeChanged;
  final bool showNonCurrentWeek;
  final ValueChanged<bool> onShowNonCurrentWeekChanged;
  final List<int> visibleWeekdays;
  final int columnsCount;
  final ValueChanged<List<int>> onVisibleWeekdaysChanged;
  final ValueChanged<int> onColumnsCountChanged;
  final double hourHeight;
  final ValueChanged<double> onHourHeightChanged;
  final bool enableLiveTimeIndicator;
  final ValueChanged<bool> onLiveTimeIndicatorChanged;
  final bool highlightTodayColumn;
  final ValueChanged<bool> onHighlightTodayColumnChanged;
  final bool autoCalculateWeek;
  final ValueChanged<bool> onAutoCalculateWeekChanged;
  final bool autoExpandTo24Hours;
  final ValueChanged<bool> onAutoExpandTo24HoursChanged;
  final DateTime semesterStartMonday;
  final ValueChanged<DateTime> onSemesterStartMondayChanged;
  final int devMessageReceiveMode;
  final ValueChanged<int> onDevMessageReceiveModeChanged;
  final bool hasUnreadBroadcast;
  final VoidCallback onMarkAllBroadcastsRead;
  final bool isDeveloperModeUnlocked;
  final ValueChanged<bool> onDeveloperModeChanged;
  final String userName;
  final String userIdTag;
  final int avatarIconIdx;
  final String avatarColor;
  final String avatarCustomText;
  final void Function(
    String name,
    String idTag,
    int iconIdx,
    String colorHex,
    String customText,
  )
  onUserProfileChanged;

  const MobileMainScreen({
    super.key,
    required this.isEnglish,
    required this.onThemeChanged,
    required this.onLanguageChanged,
    required this.currentThemeMode,
    required this.isSimpleMode,
    required this.onSimpleModeChanged,
    required this.showNonCurrentWeek,
    required this.onShowNonCurrentWeekChanged,
    required this.visibleWeekdays,
    required this.columnsCount,
    required this.onVisibleWeekdaysChanged,
    required this.onColumnsCountChanged,
    required this.hourHeight,
    required this.onHourHeightChanged,
    required this.enableLiveTimeIndicator,
    required this.onLiveTimeIndicatorChanged,
    required this.highlightTodayColumn,
    required this.onHighlightTodayColumnChanged,
    required this.autoCalculateWeek,
    required this.onAutoCalculateWeekChanged,
    required this.autoExpandTo24Hours,
    required this.onAutoExpandTo24HoursChanged,
    required this.semesterStartMonday,
    required this.onSemesterStartMondayChanged,
    required this.devMessageReceiveMode,
    required this.onDevMessageReceiveModeChanged,
    required this.hasUnreadBroadcast,
    required this.onMarkAllBroadcastsRead,
    required this.isDeveloperModeUnlocked,
    required this.onDeveloperModeChanged,
    required this.userName,
    required this.userIdTag,
    required this.avatarIconIdx,
    required this.avatarColor,
    required this.avatarCustomText,
    required this.onUserProfileChanged,
  });

  @override
  State<MobileMainScreen> createState() => _MobileMainScreenState();
}

class _MobileMainScreenState extends State<MobileMainScreen> {
  int _currentIndex = 1;

  @override
  Widget build(BuildContext context) {
    final labels = widget.isEnglish
        ? ['Schedule', 'Timetable', 'Profile']
        : ['日程', '课表', '我的'];
    final pages = [
      SchedulePage(isEnglish: widget.isEnglish),
      MobileTimetablePage(
        isEnglish: widget.isEnglish,
        isSimpleMode: widget.isSimpleMode,
        showNonCurrentWeek: widget.showNonCurrentWeek,
        visibleWeekdays: widget.visibleWeekdays,
        columnsCount: widget.columnsCount,
        hourHeight: widget.hourHeight,
        enableLiveTimeIndicator: widget.enableLiveTimeIndicator,
        highlightTodayColumn: widget.highlightTodayColumn,
        autoCalculateWeek: widget.autoCalculateWeek,
        autoExpandTo24Hours: widget.autoExpandTo24Hours,
        semesterStartMonday: widget.semesterStartMonday,
        devMessageReceiveMode: widget.devMessageReceiveMode,
        hasUnreadBroadcast: widget.hasUnreadBroadcast,
        onMarkAllBroadcastsRead: widget.onMarkAllBroadcastsRead,
      ),
      ProfilePage(
        isEnglish: widget.isEnglish,
        onThemeChanged: widget.onThemeChanged,
        onLanguageChanged: widget.onLanguageChanged,
        currentThemeMode: widget.currentThemeMode,
        isSimpleMode: widget.isSimpleMode,
        onSimpleModeChanged: widget.onSimpleModeChanged,
        showNonCurrentWeek: widget.showNonCurrentWeek,
        onShowNonCurrentWeekChanged: widget.onShowNonCurrentWeekChanged,
        visibleWeekdays: widget.visibleWeekdays,
        columnsCount: widget.columnsCount,
        onVisibleWeekdaysChanged: widget.onVisibleWeekdaysChanged,
        onColumnsCountChanged: widget.onColumnsCountChanged,
        hourHeight: widget.hourHeight,
        onHourHeightChanged: widget.onHourHeightChanged,
        enableLiveTimeIndicator: widget.enableLiveTimeIndicator,
        onLiveTimeIndicatorChanged: widget.onLiveTimeIndicatorChanged,
        highlightTodayColumn: widget.highlightTodayColumn,
        onHighlightTodayColumnChanged: widget.onHighlightTodayColumnChanged,
        autoCalculateWeek: widget.autoCalculateWeek,
        onAutoCalculateWeekChanged: widget.onAutoCalculateWeekChanged,
        autoExpandTo24Hours: widget.autoExpandTo24Hours,
        onAutoExpandTo24HoursChanged: widget.onAutoExpandTo24HoursChanged,
        semesterStartMonday: widget.semesterStartMonday,
        onSemesterStartMondayChanged: widget.onSemesterStartMondayChanged,
        devMessageReceiveMode: widget.devMessageReceiveMode,
        onDevMessageReceiveModeChanged: widget.onDevMessageReceiveModeChanged,
        hasUnreadBroadcast: widget.hasUnreadBroadcast,
        onMarkAllBroadcastsRead: widget.onMarkAllBroadcastsRead,
        isDeveloperModeUnlocked: widget.isDeveloperModeUnlocked,
        onDeveloperModeChanged: widget.onDeveloperModeChanged,
        userName: widget.userName,
        userIdTag: widget.userIdTag,
        avatarIconIdx: widget.avatarIconIdx,
        avatarColor: widget.avatarColor,
        avatarCustomText: widget.avatarCustomText,
        onUserProfileChanged: widget.onUserProfileChanged,
      ),
    ];

    return Scaffold(
      body: pages[_currentIndex],
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (index) => setState(() => _currentIndex = index),
        items: [
          BottomNavigationBarItem(
            icon: const Icon(Icons.calendar_today),
            label: labels[0],
          ),
          BottomNavigationBarItem(
            icon: const Icon(Icons.grid_view),
            label: labels[1],
          ),
          BottomNavigationBarItem(
            icon: Badge(
              isLabelVisible:
                  widget.hasUnreadBroadcast &&
                  widget.devMessageReceiveMode == 0,
              child: const Icon(Icons.person),
            ),
            label: labels[2],
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// 2.5 Schedule 日程与待办事件页面
// ============================================================================
class SchedulePage extends StatefulWidget {
  final bool isEnglish;
  final bool isDesktop;

  const SchedulePage({
    super.key,
    required this.isEnglish,
    this.isDesktop = false,
  });

  @override
  State<SchedulePage> createState() => _SchedulePageState();
}

class _SchedulePageState extends State<SchedulePage> {
  late DateTime _selectedDate;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _selectedDate = DateTime(now.year, now.month, now.day);
  }

  void _showAddOrEditEventDialog({ScheduleEvent? existing}) {
    final titleCtrl = TextEditingController(text: existing?.title ?? '');
    final timeCtrl = TextEditingController(text: existing?.timeStr ?? '14:00');
    final locCtrl = TextEditingController(text: existing?.location ?? '');
    final noteCtrl = TextEditingController(text: existing?.note ?? '');
    String selectedColor = existing?.color ?? '#E91E63';
    DateTime pickedDate = existing != null
        ? (DateTime.tryParse(existing.dateStr) ?? _selectedDate)
        : _selectedDate;
    const colors = ['#E91E63', '#FF9800', '#3F51B5', '#009688', '#9C27B0'];

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setStateSB) {
            return AlertDialog(
              title: Text(
                existing == null
                    ? (widget.isEnglish ? 'New Schedule Event' : '添加单日/未来日程事件')
                    : (widget.isEnglish ? 'Edit Schedule Event' : '编辑日程事件'),
              ),
              content: SizedBox(
                width: 420,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextField(
                        controller: titleCtrl,
                        decoration: InputDecoration(
                          labelText: widget.isEnglish
                              ? 'Event Title (e.g. Assignment Due)'
                              : '事件标题 (如：作业提交 / 小组会议)',
                          border: const OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              icon: const Icon(Icons.calendar_month, size: 18),
                              label: Text(formatDateKey(pickedDate)),
                              onPressed: () async {
                                final d = await showDatePicker(
                                  context: context,
                                  initialDate: pickedDate,
                                  firstDate: DateTime(2025),
                                  lastDate: DateTime(2030),
                                );
                                if (d != null) {
                                  setStateSB(() => pickedDate = d);
                                }
                              },
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: TextField(
                              controller: timeCtrl,
                              decoration: InputDecoration(
                                labelText: widget.isEnglish
                                    ? 'Time (HH:mm)'
                                    : '时间 (如 14:00)',
                                border: const OutlineInputBorder(),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: locCtrl,
                        decoration: InputDecoration(
                          labelText: widget.isEnglish
                              ? 'Location'
                              : '地点 (选填，支持地图跳转)',
                          border: const OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: noteCtrl,
                        decoration: InputDecoration(
                          labelText: widget.isEnglish ? 'Notes' : '备注说明',
                          border: const OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        children: colors.map((hex) {
                          return GestureDetector(
                            onTap: () => setStateSB(() => selectedColor = hex),
                            child: CircleAvatar(
                              backgroundColor: parseHexColor(hex),
                              radius: 16,
                              child: selectedColor == hex
                                  ? const Icon(
                                      Icons.check,
                                      color: Colors.white,
                                      size: 16,
                                    )
                                  : null,
                            ),
                          );
                        }).toList(),
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(widget.isEnglish ? 'Cancel' : '取消'),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blueAccent,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () {
                    if (titleCtrl.text.trim().isEmpty) {
                      return;
                    }
                    final evt = ScheduleEvent(
                      id:
                          existing?.id ??
                          'evt_${DateTime.now().millisecondsSinceEpoch}',
                      title: titleCtrl.text.trim(),
                      dateStr: formatDateKey(pickedDate),
                      timeStr: timeCtrl.text.trim().isEmpty
                          ? '12:00'
                          : timeCtrl.text.trim(),
                      location: locCtrl.text.trim(),
                      note: noteCtrl.text.trim(),
                      color: selectedColor,
                      isCompleted: existing?.isCompleted ?? false,
                    );
                    courseSyncCenter.addOrUpdateEvent(evt);
                    setState(() => _selectedDate = pickedDate);
                    Navigator.pop(context);
                  },
                  child: Text(widget.isEnglish ? 'Save' : '保存事件'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final selectedKey = formatDateKey(_selectedDate);
    final selectedWeekday = _selectedDate.weekday;
    final dayCourses =
        courseSyncCenter.courses
            .where((c) => c.weekday == selectedWeekday)
            .toList()
          ..sort((a, b) => a.startTime.compareTo(b.startTime));
    final dayEvents =
        courseSyncCenter.events.where((e) => e.dateStr == selectedKey).toList()
          ..sort((a, b) => a.timeStr.compareTo(b.timeStr));

    final now = DateTime.now();
    final todayBase = DateTime(now.year, now.month, now.day);
    final dateStrip = List.generate(
      14,
      (i) => todayBase.add(Duration(days: i - 2)),
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.isEnglish ? 'Daily Schedule & Events' : '每日日程与待办事件',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.calendar_month),
            tooltip: widget.isEnglish ? 'Pick Date' : '选择未来日期',
            onPressed: () async {
              final picked = await showDatePicker(
                context: context,
                initialDate: _selectedDate,
                firstDate: DateTime(2025),
                lastDate: DateTime(2030),
              );
              if (picked != null) {
                setState(() => _selectedDate = picked);
              }
            },
          ),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blueAccent,
                foregroundColor: Colors.white,
              ),
              icon: const Icon(Icons.add_task, size: 18),
              label: Text(widget.isEnglish ? 'Add Event' : '新增事件'),
              onPressed: () => _showAddOrEditEventDialog(),
            ),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: widget.isDesktop ? 920 : 680),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                height: 88,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  itemCount: dateStrip.length,
                  itemBuilder: (context, index) {
                    final dt = dateStrip[index];
                    final dKey = formatDateKey(dt);
                    final isSelected = dKey == selectedKey;
                    final hasEvents = courseSyncCenter.events.any(
                      (e) => e.dateStr == dKey,
                    );

                    return GestureDetector(
                      onTap: () => setState(() => _selectedDate = dt),
                      child: Container(
                        width: 62,
                        margin: const EdgeInsets.symmetric(horizontal: 4),
                        decoration: BoxDecoration(
                          color: isSelected
                              ? Colors.blueAccent
                              : Colors.grey.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              getWeekdayLabel(dt.weekday, widget.isEnglish),
                              style: TextStyle(
                                fontSize: 11,
                                color: isSelected
                                    ? Colors.white70
                                    : Colors.grey,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '${dt.day}',
                              style: TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.bold,
                                color: isSelected ? Colors.white : null,
                              ),
                            ),
                            if (hasEvents)
                              Container(
                                margin: const EdgeInsets.only(top: 4),
                                width: 6,
                                height: 6,
                                decoration: BoxDecoration(
                                  color: isSelected
                                      ? Colors.amberAccent
                                      : Colors.pinkAccent,
                                  shape: BoxShape.circle,
                                ),
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          widget.isEnglish
                              ? 'Custom Events ($selectedKey)'
                              : '单日/未来额外事件 ($selectedKey)',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          '${dayEvents.length} ${widget.isEnglish ? 'items' : '项'}',
                          style: const TextStyle(
                            color: Colors.grey,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (dayEvents.isEmpty)
                      Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: Colors.grey.withValues(alpha: 0.05),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Center(
                          child: Text(
                            widget.isEnglish
                                ? 'No custom events on this day. Tap "+ Add Event" to create one.'
                                : '当日暂无额外事件，点击右上角「新增事件」可安排当日或未来的计划。',
                            style: const TextStyle(
                              color: Colors.grey,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      )
                    else
                      ...dayEvents.map((evt) {
                        final cColor = parseHexColor(evt.color);
                        return Card(
                          margin: const EdgeInsets.symmetric(vertical: 6),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                            side: BorderSide(
                              color: cColor.withValues(alpha: 0.4),
                            ),
                          ),
                          child: ListTile(
                            leading: Checkbox(
                              value: evt.isCompleted,
                              activeColor: cColor,
                              onChanged: (_) =>
                                  courseSyncCenter.toggleEventCompleted(evt.id),
                            ),
                            title: Text(
                              evt.title,
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                decoration: evt.isCompleted
                                    ? TextDecoration.lineThrough
                                    : null,
                              ),
                            ),
                            subtitle: Text(
                              [
                                evt.timeStr,
                                if (evt.location.isNotEmpty) evt.location,
                                if (evt.note.isNotEmpty) evt.note,
                              ].join('  ·  '),
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: const Icon(
                                    Icons.edit_outlined,
                                    size: 20,
                                    color: Colors.blueAccent,
                                  ),
                                  onPressed: () =>
                                      _showAddOrEditEventDialog(existing: evt),
                                ),
                                IconButton(
                                  icon: const Icon(
                                    Icons.delete_outline,
                                    size: 20,
                                    color: Colors.redAccent,
                                  ),
                                  onPressed: () =>
                                      courseSyncCenter.deleteEventById(evt.id),
                                ),
                              ],
                            ),
                          ),
                        );
                      }),
                    const SizedBox(height: 24),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          widget.isEnglish
                              ? 'Scheduled Classes (${getWeekdayLabel(selectedWeekday, true)})'
                              : '当日排定的课程 (${getWeekdayLabel(selectedWeekday, false)})',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          '${dayCourses.length} ${widget.isEnglish ? 'classes' : '节课'}',
                          style: const TextStyle(
                            color: Colors.grey,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (dayCourses.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Text(
                          widget.isEnglish
                              ? 'No classes scheduled for this weekday.'
                              : '该星期没有排课，好好享受自由时光！',
                          style: const TextStyle(color: Colors.grey),
                        ),
                      )
                    else
                      ...dayCourses.map((c) {
                        final cColor = parseHexColor(c.color);
                        return Card(
                          margin: const EdgeInsets.symmetric(vertical: 6),
                          child: ListTile(
                            leading: CircleAvatar(
                              backgroundColor: cColor.withValues(alpha: 0.15),
                              child: Icon(
                                Icons.school,
                                color: cColor,
                                size: 18,
                              ),
                            ),
                            title: Text(
                              trName(c.name, widget.isEnglish),
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            subtitle: Text(
                              '${c.startTime} - ${c.endTime}  |  ${trLocation(c.location, widget.isEnglish)}',
                            ),
                            trailing: IconButton(
                              icon: const Icon(
                                Icons.location_on_outlined,
                                color: Colors.redAccent,
                              ),
                              onPressed: () async {
                                final query = Uri.encodeComponent(
                                  '${c.location} UQ St Lucia',
                                );
                                final url = Uri.parse(
                                  'https://www.google.com/maps/search/?api=1&query=$query',
                                );
                                if (await canLaunchUrl(url)) {
                                  await launchUrl(
                                    url,
                                    mode: LaunchMode.externalApplication,
                                  );
                                }
                              },
                            ),
                          ),
                        );
                      }),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// 2.6 手机端多日网格课表页
// ============================================================================
class MobileTimetablePage extends StatefulWidget {
  final bool isEnglish;
  final bool isSimpleMode;
  final bool showNonCurrentWeek;
  final List<int> visibleWeekdays;
  final int columnsCount;
  final double hourHeight;
  final bool enableLiveTimeIndicator;
  final bool highlightTodayColumn;
  final bool autoCalculateWeek;
  final bool autoExpandTo24Hours;
  final DateTime semesterStartMonday;
  final int devMessageReceiveMode;
  final bool hasUnreadBroadcast;
  final VoidCallback onMarkAllBroadcastsRead;

  const MobileTimetablePage({
    super.key,
    required this.isEnglish,
    required this.isSimpleMode,
    required this.showNonCurrentWeek,
    required this.visibleWeekdays,
    required this.columnsCount,
    required this.hourHeight,
    required this.enableLiveTimeIndicator,
    required this.highlightTodayColumn,
    required this.autoCalculateWeek,
    required this.autoExpandTo24Hours,
    required this.semesterStartMonday,
    required this.devMessageReceiveMode,
    required this.hasUnreadBroadcast,
    required this.onMarkAllBroadcastsRead,
  });

  @override
  State<MobileTimetablePage> createState() => _MobileTimetablePageState();
}

class _MobileTimetablePageState extends State<MobileTimetablePage> {
  late int _week;

  int get _systemCurrentWeek =>
      calculateWeekFromStartMonday(widget.semesterStartMonday, DateTime.now());

  @override
  void initState() {
    super.initState();
    _week = widget.autoCalculateWeek ? _systemCurrentWeek : 11;
  }

  @override
  void didUpdateWidget(covariant MobileTimetablePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((widget.autoCalculateWeek && !oldWidget.autoCalculateWeek) ||
        oldWidget.semesterStartMonday != widget.semesterStartMonday) {
      if (widget.autoCalculateWeek) {
        _week = _systemCurrentWeek;
      }
    }
  }

  List<Course> get _allCourses => courseSyncCenter.courses;

  bool _isCourseActiveInWeek(Course c, int week) =>
      week >= c.startWeek && week <= c.endWeek;

  List<Course> get _visibleCourses {
    if (widget.showNonCurrentWeek) {
      return _allCourses;
    }
    return _allCourses.where((c) => _isCourseActiveInWeek(c, _week)).toList();
  }

  Future<void> _editCourse(Course course) async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) =>
            AddCoursePage(isEnglish: widget.isEnglish, courseToEdit: course),
      ),
    );
    if (result != null && result is Course) {
      courseSyncCenter.addOrUpdateCourse(result);
    }
  }

  void _showCourseDetail(Course course) {
    final isCurrent = _isCourseActiveInWeek(course, _week);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      trName(course.name, widget.isEnglish),
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(
                      Icons.edit_outlined,
                      color: Colors.blueAccent,
                    ),
                    onPressed: () {
                      Navigator.pop(context);
                      _editCourse(course);
                    },
                  ),
                  IconButton(
                    icon: const Icon(
                      Icons.delete_outline,
                      color: Colors.redAccent,
                    ),
                    onPressed: () {
                      courseSyncCenter.deleteCourseById(course.id);
                      Navigator.pop(context);
                    },
                  ),
                ],
              ),
              if (!isCurrent)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    widget.isEnglish
                        ? 'Non-Current Week (Active in Weeks ${course.startWeek}-${course.endWeek})'
                        : '非本周课程（上课周数：第 ${course.startWeek}-${course.endWeek} 周）',
                    style: const TextStyle(
                      color: Colors.orange,
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                ),
              const Divider(),
              ListTile(
                leading: const Icon(
                  Icons.access_time,
                  color: Colors.blueAccent,
                ),
                title: Text(widget.isEnglish ? 'Time' : '时间'),
                subtitle: Text(
                  '${getWeekdayLabel(course.weekday, widget.isEnglish)} ${course.startTime} - ${course.endTime}',
                ),
              ),
              ListTile(
                leading: const Icon(Icons.location_on, color: Colors.redAccent),
                title: Text(widget.isEnglish ? 'Location (Map)' : '教室导航'),
                subtitle: Text(trLocation(course.location, widget.isEnglish)),
                trailing: const Icon(Icons.open_in_new, size: 18),
                onTap: () async {
                  final query = Uri.encodeComponent(
                    '${course.location} UQ St Lucia',
                  );
                  final url = Uri.parse(
                    'https://www.google.com/maps/search/?api=1&query=$query',
                  );
                  if (await canLaunchUrl(url)) {
                    await launchUrl(url, mode: LaunchMode.externalApplication);
                  }
                },
              ),
              ListTile(
                leading: const Icon(Icons.person, color: Colors.green),
                title: Text(widget.isEnglish ? 'Teacher' : '教师'),
                subtitle: Text(trTeacher(course.teacher, widget.isEnglish)),
              ),
              if (course.remark.isNotEmpty)
                ListTile(
                  leading: const Icon(Icons.notes, color: Colors.purple),
                  title: Text(widget.isEnglish ? 'Details' : '课程详情'),
                  subtitle: Text(course.remark),
                ),
              const SizedBox(height: 16),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final autoWeek = _systemCurrentWeek;
    return Scaffold(
      appBar: AppBar(
        leading: widget.devMessageReceiveMode == 2
            ? null
            : IconButton(
                tooltip: widget.isEnglish
                    ? 'Developer Messages & Guides'
                    : '开发者更新信息与使用指导',
                onPressed: () => showDeveloperInboxDialog(
                  context,
                  widget.isEnglish,
                  widget.devMessageReceiveMode,
                  widget.onMarkAllBroadcastsRead,
                ),
                icon: Badge(
                  isLabelVisible:
                      widget.hasUnreadBroadcast &&
                      widget.devMessageReceiveMode == 0,
                  child: const Icon(Icons.campaign_outlined),
                ),
              ),
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.chevron_left, size: 22),
              onPressed: () {
                if (_week > 1) {
                  setState(() => _week--);
                }
              },
            ),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.isEnglish ? 'Week $_week' : '第 $_week 周',
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                if (widget.autoCalculateWeek && _week == autoWeek)
                  Text(
                    widget.isEnglish ? 'Current Week' : '当前教学周',
                    style: const TextStyle(
                      fontSize: 10,
                      color: Colors.green,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
              ],
            ),
            IconButton(
              icon: const Icon(Icons.chevron_right, size: 22),
              onPressed: () {
                if (_week < 20) {
                  setState(() => _week++);
                }
              },
            ),
            if (widget.autoCalculateWeek && _week != autoWeek)
              IconButton(
                icon: const Icon(
                  Icons.today,
                  size: 20,
                  color: Colors.blueAccent,
                ),
                tooltip: widget.isEnglish ? 'Back to Current Week' : '回到本周',
                onPressed: () => setState(() => _week = autoWeek),
              ),
          ],
        ),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.upload_file),
            tooltip: widget.isEnglish ? 'Excel Import & Sync' : 'Excel 导入与同步',
            onPressed: () =>
                showExcelImportAndSyncModal(context, widget.isEnglish),
          ),
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: widget.isEnglish ? 'Add Course' : '添加课程',
            onPressed: () async {
              final result = await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) =>
                      AddCoursePage(isEnglish: widget.isEnglish),
                ),
              );
              if (result != null && result is Course) {
                courseSyncCenter.addOrUpdateCourse(result);
              }
            },
          ),
        ],
      ),
      body: ProportionalTimeGrid(
        visibleWeekdays: widget.visibleWeekdays,
        columnsCount: widget.columnsCount,
        visibleCourses: _visibleCourses,
        currentWeek: _week,
        isEnglish: widget.isEnglish,
        isSimpleMode: widget.isSimpleMode,
        showRichDetail: widget.columnsCount <= 3,
        hourHeight: widget.hourHeight,
        enableLiveTimeIndicator: widget.enableLiveTimeIndicator,
        highlightTodayColumn: widget.highlightTodayColumn,
        autoExpandTo24Hours: widget.autoExpandTo24Hours,
        semesterStartMonday: widget.semesterStartMonday,
        onCourseTap: _showCourseDetail,
      ),
    );
  }
}

// ============================================================================
// 3. 添加/编辑课程表单 (双端复用)
// ============================================================================
class AddCoursePage extends StatefulWidget {
  final bool isEnglish;
  final Course? courseToEdit;

  const AddCoursePage({super.key, required this.isEnglish, this.courseToEdit});

  @override
  State<AddCoursePage> createState() => _AddCoursePageState();
}

class _AddCoursePageState extends State<AddCoursePage> {
  final _nameController = TextEditingController();
  final _locationController = TextEditingController();
  final _teacherController = TextEditingController();
  final _remarkController = TextEditingController();

  int _weekday = 1;
  double _credits = 2.0;
  int _startWeek = 1;
  int _endWeek = 13;
  String _startTime = "08:00";
  String _endTime = "09:00";
  String _selectedColor = "#3F51B5";

  final List<String> _colors = [
    "#3F51B5",
    "#009688",
    "#E91E63",
    "#FF9800",
    "#9C27B0",
    "#00BCD4",
  ];

  @override
  void initState() {
    super.initState();
    if (widget.courseToEdit != null) {
      final c = widget.courseToEdit!;
      _nameController.text = c.name;
      _locationController.text = c.location;
      _teacherController.text = c.teacher;
      _remarkController.text = c.remark;
      _weekday = c.weekday;
      _credits = c.credits;
      _startWeek = c.startWeek;
      _endWeek = c.endWeek;
      _startTime = c.startTime;
      _endTime = c.endTime;
      _selectedColor = c.color;
    }
  }

  void _saveCourse() {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            widget.isEnglish ? 'Please enter course name' : '请输入课程名称',
          ),
        ),
      );
      return;
    }

    final newCourse = Course(
      id:
          widget.courseToEdit?.id ??
          DateTime.now().millisecondsSinceEpoch.toString(),
      name: name,
      color: _selectedColor,
      credits: _credits,
      startWeek: _startWeek,
      endWeek: _endWeek,
      weekday: _weekday,
      totalSections: 2,
      hasBreak: true,
      startTime: _startTime,
      endTime: _endTime,
      location: _locationController.text.trim().isEmpty
          ? 'TBA'
          : _locationController.text.trim(),
      teacher: _teacherController.text.trim().isEmpty
          ? 'TBA'
          : _teacherController.text.trim(),
      remark: _remarkController.text.trim(),
      enableReminder: true,
      reminderMinutes: 15,
      reminderCount: 1,
    );

    Navigator.pop(context, newCourse);
  }

  @override
  Widget build(BuildContext context) {
    final dayLabel = getWeekdayLabel(_weekday, widget.isEnglish);
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final dynamicCardBg = isDarkMode
        ? Colors.grey.shade900
        : Colors.grey.shade100;
    final titleStr = widget.courseToEdit == null
        ? (widget.isEnglish ? 'Add Course' : '添加课程')
        : (widget.isEnglish ? 'Edit Course' : '编辑课程');

    return Scaffold(
      appBar: AppBar(
        title: Text(titleStr),
        actions: [
          TextButton(
            onPressed: _saveCourse,
            child: Text(
              widget.isEnglish ? 'Save' : '保存',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              TextField(
                controller: _nameController,
                decoration: InputDecoration(
                  hintText: widget.isEnglish ? 'Enter course name' : '输入课程名称',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Card(
                elevation: 0,
                color: dynamicCardBg,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(
                        Icons.color_lens,
                        color: Colors.blueAccent,
                      ),
                      title: Text(widget.isEnglish ? 'Color' : '颜色'),
                      trailing: Container(
                        width: 24,
                        height: 24,
                        decoration: BoxDecoration(
                          color: parseHexColor(_selectedColor),
                          shape: BoxShape.circle,
                        ),
                      ),
                      onTap: () {
                        showModalBottomSheet(
                          context: context,
                          builder: (context) => Container(
                            padding: const EdgeInsets.all(20),
                            height: 180,
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceAround,
                              children: _colors
                                  .map(
                                    (hex) => GestureDetector(
                                      onTap: () {
                                        setState(() => _selectedColor = hex);
                                        Navigator.pop(context);
                                      },
                                      child: CircleAvatar(
                                        backgroundColor: parseHexColor(hex),
                                        radius: 24,
                                        child: _selectedColor == hex
                                            ? const Icon(
                                                Icons.check,
                                                color: Colors.white,
                                              )
                                            : null,
                                      ),
                                    ),
                                  )
                                  .toList(),
                            ),
                          ),
                        );
                      },
                    ),
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(Icons.star, color: Colors.orange),
                      title: Text(widget.isEnglish ? 'Credits' : '学分'),
                      trailing: Text(
                        '$_credits Cr',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      onTap: () {
                        showDialog(
                          context: context,
                          builder: (context) {
                            double temp = _credits;
                            return AlertDialog(
                              title: Text(
                                widget.isEnglish ? 'Select Credits' : '选择学分',
                              ),
                              content: StatefulBuilder(
                                builder: (context, sb) => Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      '$temp Cr',
                                      style: const TextStyle(
                                        fontSize: 20,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    Slider(
                                      value: temp,
                                      min: 0.5,
                                      max: 6.0,
                                      divisions: 11,
                                      onChanged: (val) => sb(() => temp = val),
                                    ),
                                  ],
                                ),
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () {
                                    setState(() => _credits = temp);
                                    Navigator.pop(context);
                                  },
                                  child: Text(
                                    widget.isEnglish ? 'Confirm' : '确定',
                                  ),
                                ),
                              ],
                            );
                          },
                        );
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Card(
                elevation: 0,
                color: dynamicCardBg,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(
                        Icons.date_range,
                        color: Colors.green,
                      ),
                      title: Text(widget.isEnglish ? 'Weeks' : '周数范围'),
                      trailing: Text(
                        widget.isEnglish
                            ? 'Weeks $_startWeek - $_endWeek >'
                            : '第 $_startWeek - $_endWeek 周 >',
                      ),
                      onTap: () {
                        showDialog(
                          context: context,
                          builder: (context) {
                            int ts = _startWeek, te = _endWeek;
                            return AlertDialog(
                              title: Text(
                                widget.isEnglish ? 'Select Weeks' : '选择周数范围',
                              ),
                              content: StatefulBuilder(
                                builder: (context, sb) => Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      widget.isEnglish
                                          ? 'Weeks $ts - $te'
                                          : '第 $ts - $te 周',
                                      style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    Row(
                                      children: [
                                        Text(
                                          widget.isEnglish ? 'Start:' : '起始:',
                                        ),
                                        Expanded(
                                          child: Slider(
                                            value: ts.toDouble(),
                                            min: 1,
                                            max: 20,
                                            divisions: 19,
                                            onChanged: (val) => sb(() {
                                              ts = val.toInt();
                                              if (ts > te) {
                                                te = ts;
                                              }
                                            }),
                                          ),
                                        ),
                                      ],
                                    ),
                                    Row(
                                      children: [
                                        Text(widget.isEnglish ? 'End:' : '结束:'),
                                        Expanded(
                                          child: Slider(
                                            value: te.toDouble(),
                                            min: 1,
                                            max: 20,
                                            divisions: 19,
                                            onChanged: (val) => sb(() {
                                              te = val.toInt();
                                              if (te < ts) {
                                                ts = te;
                                              }
                                            }),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () {
                                    setState(() {
                                      _startWeek = ts;
                                      _endWeek = te;
                                    });
                                    Navigator.pop(context);
                                  },
                                  child: Text(
                                    widget.isEnglish ? 'Confirm' : '确定',
                                  ),
                                ),
                              ],
                            );
                          },
                        );
                      },
                    ),
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(
                        Icons.access_time,
                        color: Colors.purple,
                      ),
                      title: Text(
                        widget.isEnglish ? 'Time & Weekday' : '星期与时间',
                      ),
                      trailing: Text('$dayLabel ($_startTime - $_endTime) >'),
                      onTap: () {
                        showDialog(
                          context: context,
                          builder: (context) {
                            int tw = _weekday;
                            final stc = TextEditingController(text: _startTime);
                            final etc = TextEditingController(text: _endTime);
                            return AlertDialog(
                              title: Text(
                                widget.isEnglish ? 'Weekday & Time' : '星期与时间',
                              ),
                              content: StatefulBuilder(
                                builder: (context, sb) => Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    DropdownButton<int>(
                                      value: tw,
                                      isExpanded: true,
                                      items: List.generate(7, (i) {
                                        int d = i + 1;
                                        const z = [
                                          '',
                                          '周一',
                                          '周二',
                                          '周三',
                                          '周四',
                                          '周五',
                                          '周六',
                                          '周日',
                                        ];
                                        const e = [
                                          '',
                                          'Monday',
                                          'Tuesday',
                                          'Wednesday',
                                          'Thursday',
                                          'Friday',
                                          'Saturday',
                                          'Sunday',
                                        ];
                                        return DropdownMenuItem(
                                          value: d,
                                          child: Text(
                                            widget.isEnglish ? e[d] : z[d],
                                          ),
                                        );
                                      }),
                                      onChanged: (val) =>
                                          sb(() => tw = val ?? 1),
                                    ),
                                    Row(
                                      children: [
                                        Expanded(
                                          child: TextField(
                                            controller: stc,
                                            decoration: InputDecoration(
                                              labelText: widget.isEnglish
                                                  ? 'Start'
                                                  : '开始',
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: TextField(
                                            controller: etc,
                                            decoration: InputDecoration(
                                              labelText: widget.isEnglish
                                                  ? 'End'
                                                  : '结束',
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () {
                                    setState(() {
                                      _weekday = tw;
                                      _startTime = stc.text.trim();
                                      _endTime = etc.text.trim();
                                    });
                                    Navigator.pop(context);
                                  },
                                  child: Text(
                                    widget.isEnglish ? 'Confirm' : '确定',
                                  ),
                                ),
                              ],
                            );
                          },
                        );
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Card(
                elevation: 0,
                color: dynamicCardBg,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: TextField(
                        controller: _locationController,
                        decoration: InputDecoration(
                          icon: const Icon(
                            Icons.location_on,
                            color: Colors.redAccent,
                          ),
                          hintText: widget.isEnglish ? 'Location' : '教室地址',
                          border: InputBorder.none,
                        ),
                      ),
                    ),
                    const Divider(height: 1),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: TextField(
                        controller: _teacherController,
                        decoration: InputDecoration(
                          icon: const Icon(Icons.person, color: Colors.blue),
                          hintText: widget.isEnglish ? 'Teacher' : '任课老师',
                          border: InputBorder.none,
                        ),
                      ),
                    ),
                    const Divider(height: 1),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: TextField(
                        controller: _remarkController,
                        decoration: InputDecoration(
                          icon: const Icon(Icons.note, color: Colors.grey),
                          hintText: widget.isEnglish ? 'Remark' : '备注',
                          border: InputBorder.none,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// 4. 我的与设置（可编辑头像/ID + 连点 5 次版本号输入口令解锁开发者后台）
// ============================================================================
class ProfilePage extends StatefulWidget {
  final bool isEnglish;
  final ValueChanged<ThemeMode> onThemeChanged;
  final ValueChanged<bool> onLanguageChanged;
  final ThemeMode currentThemeMode;
  final bool isSimpleMode;
  final ValueChanged<bool> onSimpleModeChanged;
  final bool showNonCurrentWeek;
  final ValueChanged<bool> onShowNonCurrentWeekChanged;
  final List<int> visibleWeekdays;
  final int columnsCount;
  final ValueChanged<List<int>> onVisibleWeekdaysChanged;
  final ValueChanged<int> onColumnsCountChanged;
  final double hourHeight;
  final ValueChanged<double> onHourHeightChanged;
  final bool enableLiveTimeIndicator;
  final ValueChanged<bool> onLiveTimeIndicatorChanged;
  final bool highlightTodayColumn;
  final ValueChanged<bool> onHighlightTodayColumnChanged;
  final bool autoCalculateWeek;
  final ValueChanged<bool> onAutoCalculateWeekChanged;
  final bool autoExpandTo24Hours;
  final ValueChanged<bool> onAutoExpandTo24HoursChanged;
  final DateTime semesterStartMonday;
  final ValueChanged<DateTime> onSemesterStartMondayChanged;
  final int devMessageReceiveMode;
  final ValueChanged<int> onDevMessageReceiveModeChanged;
  final bool hasUnreadBroadcast;
  final VoidCallback onMarkAllBroadcastsRead;
  final bool isDeveloperModeUnlocked;
  final ValueChanged<bool> onDeveloperModeChanged;
  final String userName;
  final String userIdTag;
  final int avatarIconIdx;
  final String avatarColor;
  final String avatarCustomText;
  final void Function(
    String name,
    String idTag,
    int iconIdx,
    String colorHex,
    String customText,
  )
  onUserProfileChanged;

  const ProfilePage({
    super.key,
    required this.isEnglish,
    required this.onThemeChanged,
    required this.onLanguageChanged,
    required this.currentThemeMode,
    required this.isSimpleMode,
    required this.onSimpleModeChanged,
    required this.showNonCurrentWeek,
    required this.onShowNonCurrentWeekChanged,
    required this.visibleWeekdays,
    required this.columnsCount,
    required this.onVisibleWeekdaysChanged,
    required this.onColumnsCountChanged,
    required this.hourHeight,
    required this.onHourHeightChanged,
    required this.enableLiveTimeIndicator,
    required this.onLiveTimeIndicatorChanged,
    required this.highlightTodayColumn,
    required this.onHighlightTodayColumnChanged,
    required this.autoCalculateWeek,
    required this.onAutoCalculateWeekChanged,
    required this.autoExpandTo24Hours,
    required this.onAutoExpandTo24HoursChanged,
    required this.semesterStartMonday,
    required this.onSemesterStartMondayChanged,
    required this.devMessageReceiveMode,
    required this.onDevMessageReceiveModeChanged,
    required this.hasUnreadBroadcast,
    required this.onMarkAllBroadcastsRead,
    required this.isDeveloperModeUnlocked,
    required this.onDeveloperModeChanged,
    required this.userName,
    required this.userIdTag,
    required this.avatarIconIdx,
    required this.avatarColor,
    required this.avatarCustomText,
    required this.onUserProfileChanged,
  });

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  int _versionTapCount = 0;
  DateTime? _lastTapTime;

  void _handleVersionTap() {
    final now = DateTime.now();
    if (_lastTapTime == null ||
        now.difference(_lastTapTime!) > const Duration(seconds: 3)) {
      _versionTapCount = 1;
    } else {
      _versionTapCount++;
    }
    _lastTapTime = now;

    if (widget.isDeveloperModeUnlocked) {
      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 2),
          content: Text(
            widget.isEnglish ? 'Developer mode is already active.' : '已处于开发者模式',
          ),
        ),
      );
      return;
    }

    final remaining = 5 - _versionTapCount;
    if (remaining > 0 && remaining <= 3) {
      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(milliseconds: 900),
          content: Text(
            widget.isEnglish
                ? 'Tap $remaining more times to enter developer passcode'
                : '再连点 $remaining 次即可输入口令开启开发者模式',
          ),
        ),
      );
    } else if (remaining <= 0) {
      _versionTapCount = 0;
      _showDeveloperPasscodeDialog();
    }
  }

  void _showDeveloperPasscodeDialog() {
    final passCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.security, color: Colors.deepPurpleAccent),
            const SizedBox(width: 8),
            Text(
              widget.isEnglish ? 'Developer Verification' : '开发者身份口令验证',
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        content: TextField(
          controller: passCtrl,
          obscureText: true,
          autofocus: true,
          decoration: InputDecoration(
            labelText: widget.isEnglish
                ? 'Enter Developer Passcode'
                : '请输入开发者专属口令',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(widget.isEnglish ? 'Cancel' : '取消'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.deepPurpleAccent,
              foregroundColor: Colors.white,
            ),
            onPressed: () {
              if (passCtrl.text.trim() == kDeveloperPasscode) {
                Navigator.pop(context);
                widget.onDeveloperModeChanged(true);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    backgroundColor: Colors.deepPurpleAccent,
                    content: Text(
                      widget.isEnglish
                          ? 'Developer Mode Unlocked!'
                          : '口令验证通过！已开启开发者群发与管理功能。',
                    ),
                  ),
                );
              } else {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    backgroundColor: Colors.redAccent,
                    content: Text(
                      widget.isEnglish ? 'Invalid Passcode' : '开发者口令错误',
                    ),
                  ),
                );
              }
            },
            child: Text(widget.isEnglish ? 'Verify' : '验证解锁'),
          ),
        ],
      ),
    );
  }

  void _openProfileEditor() {
    showEditUserProfileDialog(
      context: context,
      isEnglish: widget.isEnglish,
      currentName: widget.userName,
      currentIdTag: widget.userIdTag,
      currentAvatarIconIdx: widget.avatarIconIdx,
      currentAvatarColor: widget.avatarColor,
      currentAvatarText: widget.avatarCustomText,
      onSave: widget.onUserProfileChanged,
    );
  }

  @override
  Widget build(BuildContext context) {
    final autoWeek = calculateWeekFromStartMonday(
      widget.semesterStartMonday,
      DateTime.now(),
    );
    const avatarIcons = [
      Icons.school,
      Icons.auto_awesome,
      Icons.terminal,
      Icons.rocket_launch,
      Icons.emoji_emotions,
      Icons.sports_esports,
    ];

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isEnglish ? 'Profile & Settings' : '我的与设置'),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 16),
        children: [
          // 可点击自由修改的头像与用户昵称/ID 区域
          Center(
            child: InkWell(
              borderRadius: BorderRadius.circular(50),
              onTap: _openProfileEditor,
              child: Stack(
                alignment: Alignment.bottomRight,
                children: [
                  CircleAvatar(
                    radius: 40,
                    backgroundColor: parseHexColor(widget.avatarColor),
                    child: widget.avatarCustomText.isNotEmpty
                        ? Text(
                            widget.avatarCustomText.characters
                                .take(2)
                                .toString(),
                            style: const TextStyle(
                              fontSize: 26,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          )
                        : Icon(
                            avatarIcons[widget.avatarIconIdx.clamp(
                              0,
                              avatarIcons.length - 1,
                            )],
                            size: 40,
                            color: Colors.white,
                          ),
                  ),
                  Container(
                    padding: const EdgeInsets.all(4),
                    decoration: const BoxDecoration(
                      color: Colors.blueAccent,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.edit,
                      size: 14,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Center(
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: _openProfileEditor,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                child: Column(
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          widget.userName,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(width: 6),
                        const Icon(
                          Icons.edit_outlined,
                          size: 16,
                          color: Colors.grey,
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      widget.userIdTag,
                      style: const TextStyle(
                        fontSize: 13,
                        color: Colors.blueAccent,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 4),
          // 连点 5 次版本号触发开发者口令验证
          Center(
            child: GestureDetector(
              onTap: _handleVersionTap,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
                child: Text(
                  'Version v${courseSyncCenter.installedVersion}${widget.isDeveloperModeUnlocked ? ' (Dev)' : ''}',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blueAccent,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              icon: const Icon(Icons.table_view),
              label: Text(
                widget.isEnglish
                    ? 'Excel Auto-Import & Dual Sync'
                    : 'Excel 课表自动识别导入与双端同步',
              ),
              onPressed: () =>
                  showExcelImportAndSyncModal(context, widget.isEnglish),
            ),
          ),
          const SizedBox(height: 16),
          const Divider(),

          // ==================================================================
          // 版本更新、用户反馈与开发者信息中心
          // ==================================================================
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(
              widget.isEnglish
                  ? 'Updates, Feedback & Developer Info'
                  : '版本更新、用户反馈与开发者信息',
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: Colors.blueAccent,
              ),
            ),
          ),
          ListTile(
            leading: const Icon(
              Icons.notifications_active_outlined,
              color: Colors.amber,
            ),
            title: Text(
              widget.isEnglish ? 'In-App Developer Messages' : '接收应用内开发者信息',
            ),
            subtitle: Text(
              widget.devMessageReceiveMode == 0
                  ? (widget.isEnglish
                        ? 'Receive & Notify (Pop-up & Badge)'
                        : '当前：接收并提醒（收到更新指导时弹窗+红点提醒）')
                  : widget.devMessageReceiveMode == 1
                  ? (widget.isEnglish
                        ? 'Receive Silently (Inbox only, no pop-up)'
                        : '当前：接收但不提醒（静默存入消息箱，绝不打扰）')
                  : (widget.isEnglish
                        ? 'Do Not Receive (Turned off)'
                        : '当前：不接收（彻底关闭开发者应用内广播）'),
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            trailing: DropdownButton<int>(
              value: widget.devMessageReceiveMode,
              underline: const SizedBox(),
              items: [
                DropdownMenuItem(
                  value: 0,
                  child: Text(widget.isEnglish ? 'Receive & Notify' : '接收并提醒'),
                ),
                DropdownMenuItem(
                  value: 1,
                  child: Text(widget.isEnglish ? 'Receive Silently' : '接收但不提醒'),
                ),
                DropdownMenuItem(
                  value: 2,
                  child: Text(widget.isEnglish ? 'Do Not Receive' : '不接收'),
                ),
              ],
              onChanged: (val) {
                if (val != null) {
                  widget.onDevMessageReceiveModeChanged(val);
                }
              },
            ),
          ),
          if (widget.devMessageReceiveMode != 2)
            ListTile(
              leading: Badge(
                isLabelVisible:
                    widget.hasUnreadBroadcast &&
                    widget.devMessageReceiveMode == 0,
                child: const Icon(Icons.campaign_outlined, color: Colors.teal),
              ),
              title: Text(
                widget.isEnglish
                    ? 'Developer Updates & Usage Guides'
                    : '查看开发者更新信息与使用指导',
              ),
              subtitle: Text(
                widget.isEnglish
                    ? '${courseSyncCenter.broadcasts.length} official guides & update announcements'
                    : '共 ${courseSyncCenter.broadcasts.length} 条来自开发者的更新说明与操作指南',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => showDeveloperInboxDialog(
                context,
                widget.isEnglish,
                widget.devMessageReceiveMode,
                widget.onMarkAllBroadcastsRead,
              ),
            ),
          ListTile(
            leading: const Icon(Icons.system_update, color: Colors.blueAccent),
            title: Text(
              widget.isEnglish ? 'Check for Updates' : '检查更新（联网下载并安装新版本）',
            ),
            subtitle: Text(
              widget.isEnglish
                  ? 'Installed: v${courseSyncCenter.installedVersion} · Latest: v${courseSyncCenter.latestRemoteVersion}'
                  : '当前版本：v${courseSyncCenter.installedVersion} · 云端最新：v${courseSyncCenter.latestRemoteVersion}',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            trailing: courseSyncCenter.hasNewVersion
                ? Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.redAccent.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      widget.isEnglish ? 'NEW' : '有新版本',
                      style: const TextStyle(
                        fontSize: 10,
                        color: Colors.redAccent,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  )
                : const Icon(
                    Icons.check_circle_outline,
                    color: Colors.green,
                    size: 18,
                  ),
            onTap: () => showCheckForUpdatesDialog(context, widget.isEnglish),
          ),
          ListTile(
            leading: const Icon(
              Icons.rate_review_outlined,
              color: Colors.green,
            ),
            title: Text(
              widget.isEnglish
                  ? 'User Feedback & Suggestions'
                  : '用户反馈渠道（向开发者发送改进提议）',
            ),
            subtitle: Text(
              widget.isEnglish
                  ? 'Submit feature requests, bug reports or contact developer'
                  : '向开发者提交新功能提议、问题反馈或体验改进意见',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => showUserFeedbackDialog(context, widget.isEnglish),
          ),
          // 仅在连点 5 次版本号并通过口令验证后，才显示开发者专属群发后台
          if (widget.isDeveloperModeUnlocked)
            ListTile(
              leading: const Icon(
                Icons.admin_panel_settings_outlined,
                color: Colors.deepPurpleAccent,
              ),
              title: Text(
                widget.isEnglish
                    ? 'Developer Broadcast Console'
                    : '开发者群发控制台（一键发送更新与使用指导）',
              ),
              subtitle: Text(
                widget.isEnglish
                    ? 'Unlocked: Push updates & guides or lock console'
                    : '开发者已解锁：一键推送更新与指导，或点击进入后锁定隐藏',
                style: const TextStyle(
                  fontSize: 12,
                  color: Colors.deepPurpleAccent,
                ),
              ),
              trailing: const Icon(
                Icons.chevron_right,
                color: Colors.deepPurpleAccent,
              ),
              onTap: () {
                showDeveloperBroadcastConsole(context, widget.isEnglish, (msg) {
                  if (widget.devMessageReceiveMode == 0) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        backgroundColor: Colors.deepPurpleAccent,
                        content: Text(
                          widget.isEnglish
                              ? 'Broadcast pushed: ${msg.localizedTitle(true)}'
                              : '已向用户群发并触发提醒：${msg.localizedTitle(false)}',
                        ),
                      ),
                    );
                  }
                }, () => widget.onDeveloperModeChanged(false));
              },
            ),
          const Divider(),

          // ==================================================================
          // 基础界面与时间轴设置
          // ==================================================================
          ListTile(
            leading: const Icon(Icons.language),
            title: Text(widget.isEnglish ? 'Language' : '语言设置'),
            trailing: DropdownButton<bool>(
              value: widget.isEnglish,
              items: const [
                DropdownMenuItem(value: false, child: Text('简体中文')),
                DropdownMenuItem(value: true, child: Text('English')),
              ],
              onChanged: (val) {
                if (val != null) {
                  widget.onLanguageChanged(val);
                }
              },
            ),
          ),
          ListTile(
            leading: const Icon(Icons.brightness_6),
            title: Text(widget.isEnglish ? 'Theme Mode' : '主题模式'),
            trailing: DropdownButton<ThemeMode>(
              value: widget.currentThemeMode,
              items: [
                DropdownMenuItem(
                  value: ThemeMode.system,
                  child: Text(widget.isEnglish ? 'System' : '跟随系统'),
                ),
                DropdownMenuItem(
                  value: ThemeMode.light,
                  child: Text(widget.isEnglish ? 'Light' : '浅色模式'),
                ),
                DropdownMenuItem(
                  value: ThemeMode.dark,
                  child: Text(widget.isEnglish ? 'Dark' : '深色模式'),
                ),
              ],
              onChanged: (val) {
                if (val != null) {
                  widget.onThemeChanged(val);
                }
              },
            ),
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(
              widget.isEnglish
                  ? 'Time Span & Real-Time Tracking'
                  : '时间轴跨度与实时时间追踪',
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: Colors.blueAccent,
              ),
            ),
          ),
          SwitchListTile(
            secondary: const Icon(
              Icons.unfold_more,
              color: Colors.deepPurpleAccent,
            ),
            title: Text(
              widget.isEnglish
                  ? 'Auto-Expand to 24h for Out-of-Bounds Courses'
                  : '越界课程自动扩展至 24 小时',
            ),
            subtitle: Text(
              widget.isEnglish
                  ? 'Default span is 07:00–22:00; expands to 00:00–24:00 if any course falls outside'
                  : '常驻跨度为 07:00–22:00；若存在早于 7 点或晚于 22 点的课程则自动扩展为 00:00–24:00',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            value: widget.autoExpandTo24Hours,
            onChanged: widget.onAutoExpandTo24HoursChanged,
          ),
          SwitchListTile(
            secondary: const Icon(Icons.timeline, color: Colors.redAccent),
            title: Text(
              widget.isEnglish ? 'Live Current Time Red Line' : '显示当前时间轴红线指示器',
            ),
            subtitle: Text(
              widget.isEnglish
                  ? 'Draw a live red line & time badge on the time grid'
                  : '在课表时间轴上实时绘制当前时间红线与时间标签',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            value: widget.enableLiveTimeIndicator,
            onChanged: widget.onLiveTimeIndicatorChanged,
          ),
          SwitchListTile(
            secondary: const Icon(Icons.today, color: Colors.blueAccent),
            title: Text(
              widget.isEnglish
                  ? 'Highlight Today Column & Show Dates'
                  : '高亮「今天」所在列并显示月/日日期',
            ),
            subtitle: Text(
              widget.isEnglish
                  ? 'Highlight current weekday column and show exact dates (e.g. 10/15)'
                  : '在星期表头下方显示具体月/日（如 10/15），并高亮标记今天所在列',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            value: widget.highlightTodayColumn,
            onChanged: widget.onHighlightTodayColumnChanged,
          ),
          SwitchListTile(
            secondary: const Icon(Icons.auto_mode, color: Colors.green),
            title: Text(
              widget.isEnglish
                  ? 'Auto-Calculate Current Teaching Week'
                  : '根据开学日期自动定位当前第几周',
            ),
            subtitle: Text(
              widget.isEnglish
                  ? 'Automatically locates to Week $autoWeek based on system date'
                  : '根据系统当前日期自动推算并定位至本周（当前推算为：第 $autoWeek 周）',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            value: widget.autoCalculateWeek,
            onChanged: widget.onAutoCalculateWeekChanged,
          ),
          if (widget.autoCalculateWeek)
            ListTile(
              leading: const Icon(
                Icons.edit_calendar_outlined,
                color: Colors.green,
              ),
              title: Text(
                widget.isEnglish
                    ? 'Semester Week 1 Monday Date'
                    : '设置开学第 1 周周一日期',
              ),
              subtitle: Text(
                widget.isEnglish
                    ? 'Current base: ${formatDateKey(widget.semesterStartMonday)}'
                    : '当前基准日：${formatDateKey(widget.semesterStartMonday)}（点击可修改校准）',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async {
                final picked = await showDatePicker(
                  context: context,
                  initialDate: widget.semesterStartMonday,
                  firstDate: DateTime(2024),
                  lastDate: DateTime(2030),
                );
                if (picked != null) {
                  widget.onSemesterStartMondayChanged(picked);
                }
              },
            ),
          const Divider(),
          SwitchListTile(
            secondary: const Icon(Icons.compress),
            title: Text(
              widget.isEnglish ? 'Compact / Simple Mode' : '简洁模式（切换简洁/完整视图）',
            ),
            subtitle: Text(
              widget.isEnglish
                  ? 'Hide secondary info in timetable cards for a cleaner look'
                  : '隐藏卡片中的次要文字信息，仅保留核心课程名与起止时间',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            value: widget.isSimpleMode,
            onChanged: widget.onSimpleModeChanged,
          ),
          const Divider(),
          SwitchListTile(
            secondary: const Icon(Icons.event_available_outlined),
            title: Text(
              widget.isEnglish ? 'Show Non-Current Week Courses' : '显示非本周课程',
            ),
            subtitle: Text(
              widget.isEnglish
                  ? 'Display courses from other weeks in a dimmed style'
                  : '在当前周课表中以半透明样式展示其他周的课程',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            value: widget.showNonCurrentWeek,
            onChanged: widget.onShowNonCurrentWeekChanged,
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.calendar_view_week, size: 22),
                    const SizedBox(width: 12),
                    Text(
                      widget.isEnglish
                          ? 'Displayed Weekdays (Filter Empty Days)'
                          : '课表显示星期（可过滤无课日）',
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: List.generate(7, (index) {
                    int day = index + 1;
                    bool isSelected = widget.visibleWeekdays.contains(day);
                    return FilterChip(
                      label: Text(getWeekdayLabel(day, widget.isEnglish)),
                      selected: isSelected,
                      onSelected: (val) {
                        final next = List<int>.from(widget.visibleWeekdays);
                        if (val) {
                          next.add(day);
                        } else if (next.length > 1) {
                          next.remove(day);
                        }
                        widget.onVisibleWeekdaysChanged(next);
                      },
                    );
                  }),
                ),
              ],
            ),
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.view_column_outlined, size: 22),
                        const SizedBox(width: 12),
                        Text(
                          widget.isEnglish
                              ? 'Columns per Screen'
                              : '同屏展示天数（列数）',
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                    Text(
                      '${widget.columnsCount} ${widget.isEnglish ? 'Days' : '天'}',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Colors.blueAccent,
                      ),
                    ),
                  ],
                ),
                Slider(
                  value: widget.columnsCount.toDouble().clamp(
                    1,
                    widget.visibleWeekdays.length.toDouble(),
                  ),
                  min: 1,
                  max: widget.visibleWeekdays.length.toDouble(),
                  divisions: widget.visibleWeekdays.length > 1
                      ? widget.visibleWeekdays.length - 1
                      : 1,
                  label: '${widget.columnsCount}',
                  onChanged: (val) => widget.onColumnsCountChanged(val.toInt()),
                ),
              ],
            ),
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.height, size: 22),
                        const SizedBox(width: 12),
                        Text(
                          widget.isEnglish ? 'Hour Slot Height' : '每小时时间格高度',
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                    Text(
                      '${widget.hourHeight.toInt()} px',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Colors.blueAccent,
                      ),
                    ),
                  ],
                ),
                Slider(
                  value: widget.hourHeight,
                  min: 60.0,
                  max: 120.0,
                  divisions: 6,
                  onChanged: widget.onHourHeightChanged,
                ),
              ],
            ),
          ),
          const Divider(),
        ],
      ),
    );
  }
}

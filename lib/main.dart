import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:timetable_app/src/rust/api/simple.dart';
import 'package:timetable_app/src/rust/frb_generated.dart';
import 'package:url_launcher/url_launcher.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
// 全局双端同步与 Excel 自动识别解析引擎
// ============================================================================
class CourseSyncController extends ChangeNotifier {
  List<Course> _courses = [];
  List<ScheduleEvent> _events = [];

  List<Course> get courses => List.unmodifiable(_courses);
  List<ScheduleEvent> get events => List.unmodifiable(_events);

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

    if (!kIsWeb) {
      try {
        final Map<String, Course> merged = {for (final c in _courses) c.id: c};
        for (int w = 1; w <= 20; w++) {
          for (final c in getCoursesForWeek(week: w)) {
            if (c.id != "1") {
              merged[c.id] = c;
            }
          }
        }
        for (final c in _courses) {
          addCourse(course: c);
        }
        _courses = merged.values.toList();
      } catch (e) {
        debugPrint("Sync with Rust skipped: $e");
      }
    }
    notifyListeners();
  }

  void addOrUpdateCourse(Course course) {
    final idx = _courses.indexWhere((c) => c.id == course.id);
    if (idx != -1) {
      _courses[idx] = course;
    } else {
      _courses.add(course);
      if (!kIsWeb) {
        try {
          addCourse(course: course);
        } catch (_) {}
      }
    }
    notifyListeners();
  }

  void deleteCourseById(String id) {
    _courses.removeWhere((c) => c.id == id);
    notifyListeners();
  }

  void addOrUpdateEvent(ScheduleEvent event) {
    final idx = _events.indexWhere((e) => e.id == event.id);
    if (idx != -1) {
      _events[idx] = event;
    } else {
      _events.add(event);
    }
    notifyListeners();
  }

  void toggleEventCompleted(String id) {
    final idx = _events.indexWhere((e) => e.id == id);
    if (idx != -1) {
      _events[idx] = _events[idx].copyWith(
        isCompleted: !_events[idx].isCompleted,
      );
      notifyListeners();
    }
  }

  void deleteEventById(String id) {
    _events.removeWhere((e) => e.id == id);
    notifyListeners();
  }

  void importCourses(List<Course> newCourses, {bool replaceAll = false}) {
    if (replaceAll) {
      _courses = List.from(newCourses);
    } else {
      final Map<String, Course> map = {for (final c in _courses) c.id: c};
      for (final c in newCourses) {
        map[c.id] = c;
        if (!kIsWeb) {
          try {
            addCourse(course: c);
          } catch (_) {}
        }
      }
      _courses = map.values.toList();
    }
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
    return jsonEncode({'courses': courseList, 'events': eventList});
  }

  int importFromSyncJson(String jsonStr, {bool replaceAll = true}) {
    final dynamic decoded = jsonDecode(jsonStr);
    List<dynamic> rawCourses = [];
    List<dynamic> rawEvents = [];

    if (decoded is List) {
      rawCourses = decoded;
    } else if (decoded is Map<String, dynamic>) {
      rawCourses = (decoded['courses'] as List<dynamic>?) ?? [];
      rawEvents = (decoded['events'] as List<dynamic>?) ?? [];
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

    if (rawEvents.isNotEmpty) {
      _events = rawEvents
          .map((e) => ScheduleEvent.fromJson(e as Map<String, dynamic>))
          .toList();
    }
    importCourses(parsedCourses, replaceAll: replaceAll);
    return parsedCourses.length;
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

// ============================================================================
// 二维比例时间轴周课表组件（常驻 07:00-22:00，支持越界课程自动扩展至 00:00-24:00）
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
  static const int residentStartHour = 7; // 常驻起点 07:00
  static const int residentEndHour = 22; // 常驻终点 22:00
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

  // 判断是否存在早于 07:00 或晚于 22:00 的越界课程
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
              // 左侧固定时间标尺列
              SizedBox(
                width: timeAxisWidth,
                height: headerHeight + totalGridHeight,
                child: Column(
                  children: [
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
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.schedule,
                            size: 14,
                            color: Colors.grey.shade500,
                          ),
                          Text(
                            expandToFullDay ? '24h' : '7-22',
                            style: TextStyle(
                              fontSize: 9,
                              color: Colors.grey.shade500,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
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
              // 右侧可横向滑动区域
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SizedBox(
                    width: totalRowWidth,
                    height: headerHeight + totalGridHeight,
                    child: Column(
                      children: [
                        // 1. 星期表头行
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
                        // 2. 二维时间轴绝对坐标网格
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
                          ? 'Generate a sync code on PC Web and paste it on Mobile App (or vice versa) to sync all courses & schedule events instantly:'
                          : '在电脑网页端或手机端一键复制“同步码”，在另一端粘贴即可实现双端课表与日程事件秒级同步：',
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

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  ThemeMode _themeMode = ThemeMode.system;
  bool _isEnglish = false;
  bool _isSimpleMode = false;
  bool _showNonCurrentWeek = false;
  List<int> _visibleWeekdays = [1, 2, 3, 4, 5, 6, 7];
  int _columnsCount = 5;
  double _hourHeight = 84.0;

  bool _enableLiveTimeIndicator = true;
  bool _highlightTodayColumn = true;
  bool _autoCalculateWeek = true;
  bool _autoExpandTo24Hours = true; // 新增：当有课程超出 07:00-22:00 时，自动扩展到 24 小时
  DateTime _semesterStartMonday = DateTime(2026, 8, 3);

  void _toggleTheme(ThemeMode mode) => setState(() => _themeMode = mode);
  void _toggleLanguage(bool isEnglish) =>
      setState(() => _isEnglish = isEnglish);
  void _toggleSimpleMode(bool val) => setState(() => _isSimpleMode = val);
  void _toggleShowNonCurrentWeek(bool val) =>
      setState(() => _showNonCurrentWeek = val);
  void _updateHourHeight(double val) => setState(() => _hourHeight = val);

  void _toggleLiveTimeIndicator(bool val) =>
      setState(() => _enableLiveTimeIndicator = val);
  void _toggleHighlightTodayColumn(bool val) =>
      setState(() => _highlightTodayColumn = val);
  void _toggleAutoCalculateWeek(bool val) =>
      setState(() => _autoCalculateWeek = val);
  void _toggleAutoExpandTo24Hours(bool val) =>
      setState(() => _autoExpandTo24Hours = val);

  void _updateSemesterStartMonday(DateTime dt) {
    final monday = dt.subtract(Duration(days: dt.weekday - 1));
    setState(
      () => _semesterStartMonday = DateTime(
        monday.year,
        monday.month,
        monday.day,
      ),
    );
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
  }

  void _updateColumnsCount(int count) {
    setState(() {
      _columnsCount = count;
    });
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
          ),
        );
      },
    );
  }
}

class ResponsiveRoot extends StatelessWidget {
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
  });

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    if (kIsWeb && screenWidth > 900) {
      return DesktopLuxuryWorkspace(
        isEnglish: isEnglish,
        onThemeChanged: onThemeChanged,
        onLanguageChanged: onLanguageChanged,
        currentThemeMode: currentThemeMode,
        isSimpleMode: isSimpleMode,
        onSimpleModeChanged: onSimpleModeChanged,
        showNonCurrentWeek: showNonCurrentWeek,
        onShowNonCurrentWeekChanged: onShowNonCurrentWeekChanged,
        visibleWeekdays: visibleWeekdays,
        columnsCount: columnsCount,
        onVisibleWeekdaysChanged: onVisibleWeekdaysChanged,
        onColumnsCountChanged: onColumnsCountChanged,
        hourHeight: hourHeight,
        onHourHeightChanged: onHourHeightChanged,
        enableLiveTimeIndicator: enableLiveTimeIndicator,
        onLiveTimeIndicatorChanged: onLiveTimeIndicatorChanged,
        highlightTodayColumn: highlightTodayColumn,
        onHighlightTodayColumnChanged: onHighlightTodayColumnChanged,
        autoCalculateWeek: autoCalculateWeek,
        onAutoCalculateWeekChanged: onAutoCalculateWeekChanged,
        autoExpandTo24Hours: autoExpandTo24Hours,
        onAutoExpandTo24HoursChanged: onAutoExpandTo24HoursChanged,
        semesterStartMonday: semesterStartMonday,
        onSemesterStartMondayChanged: onSemesterStartMondayChanged,
      );
    } else {
      return MobileMainScreen(
        isEnglish: isEnglish,
        onThemeChanged: onThemeChanged,
        onLanguageChanged: onLanguageChanged,
        currentThemeMode: currentThemeMode,
        isSimpleMode: isSimpleMode,
        onSimpleModeChanged: onSimpleModeChanged,
        showNonCurrentWeek: showNonCurrentWeek,
        onShowNonCurrentWeekChanged: onShowNonCurrentWeekChanged,
        visibleWeekdays: visibleWeekdays,
        columnsCount: columnsCount,
        onVisibleWeekdaysChanged: onVisibleWeekdaysChanged,
        onColumnsCountChanged: onColumnsCountChanged,
        hourHeight: hourHeight,
        onHourHeightChanged: onHourHeightChanged,
        enableLiveTimeIndicator: enableLiveTimeIndicator,
        onLiveTimeIndicatorChanged: onLiveTimeIndicatorChanged,
        highlightTodayColumn: highlightTodayColumn,
        onHighlightTodayColumnChanged: onHighlightTodayColumnChanged,
        autoCalculateWeek: autoCalculateWeek,
        onAutoCalculateWeekChanged: onAutoCalculateWeekChanged,
        autoExpandTo24Hours: autoExpandTo24Hours,
        onAutoExpandTo24HoursChanged: onAutoExpandTo24HoursChanged,
        semesterStartMonday: semesterStartMonday,
        onSemesterStartMondayChanged: onSemesterStartMondayChanged,
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
                        subtitle: InkWell(
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
                          child: Text(
                            widget.isEnglish
                                ? 'Week 1 Mon: ${formatDateKey(widget.semesterStartMonday)} (Tap to edit)'
                                : '第1周周一: ${formatDateKey(widget.semesterStartMonday)} (点击修改)',
                            style: const TextStyle(
                              fontSize: 11,
                              color: Colors.blueAccent,
                            ),
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
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            widget.isEnglish ? 'Hour Height' : '每小时时间格高度',
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: Colors.grey,
                            ),
                          ),
                          Text(
                            '${widget.hourHeight.toInt()} px',
                            style: const TextStyle(
                              fontSize: 12,
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
            icon: const Icon(Icons.person),
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
// 4. 我的与设置（含常驻 07:00-22:00 与越界课程自动扩展 24 小时开关）
// ============================================================================
class ProfilePage extends StatelessWidget {
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
  });

  @override
  Widget build(BuildContext context) {
    final autoWeek = calculateWeekFromStartMonday(
      semesterStartMonday,
      DateTime.now(),
    );

    return Scaffold(
      appBar: AppBar(title: Text(isEnglish ? 'Profile & Settings' : '我的与设置')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 16),
        children: [
          const CircleAvatar(
            radius: 36,
            backgroundColor: Colors.blueAccent,
            child: Icon(Icons.school, size: 36, color: Colors.white),
          ),
          const SizedBox(height: 10),
          Center(
            child: Text(
              isEnglish ? 'UQ St Lucia Timetable' : 'UQ 圣卢西亚校区课表',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(height: 20),
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
                isEnglish
                    ? 'Excel Auto-Import & Dual Sync'
                    : 'Excel 课表自动识别导入与双端同步',
              ),
              onPressed: () => showExcelImportAndSyncModal(context, isEnglish),
            ),
          ),
          const SizedBox(height: 12),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.language),
            title: Text(isEnglish ? 'Language' : '语言设置'),
            trailing: DropdownButton<bool>(
              value: isEnglish,
              items: const [
                DropdownMenuItem(value: false, child: Text('简体中文')),
                DropdownMenuItem(value: true, child: Text('English')),
              ],
              onChanged: (val) {
                if (val != null) {
                  onLanguageChanged(val);
                }
              },
            ),
          ),
          ListTile(
            leading: const Icon(Icons.brightness_6),
            title: Text(isEnglish ? 'Theme Mode' : '主题模式'),
            trailing: DropdownButton<ThemeMode>(
              value: currentThemeMode,
              items: [
                DropdownMenuItem(
                  value: ThemeMode.system,
                  child: Text(isEnglish ? 'System' : '跟随系统'),
                ),
                DropdownMenuItem(
                  value: ThemeMode.light,
                  child: Text(isEnglish ? 'Light' : '浅色模式'),
                ),
                DropdownMenuItem(
                  value: ThemeMode.dark,
                  child: Text(isEnglish ? 'Dark' : '深色模式'),
                ),
              ],
              onChanged: (val) {
                if (val != null) {
                  onThemeChanged(val);
                }
              },
            ),
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(
              isEnglish ? 'Time Span & Real-Time Tracking' : '时间轴跨度与实时时间追踪',
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: Colors.blueAccent,
              ),
            ),
          ),
          // 新增：当课表存在 07:00-22:00 以外的课程时，自动扩展为 24 小时
          SwitchListTile(
            secondary: const Icon(
              Icons.unfold_more,
              color: Colors.deepPurpleAccent,
            ),
            title: Text(
              isEnglish
                  ? 'Auto-Expand to 24h for Out-of-Bounds Courses'
                  : '越界课程自动扩展至 24 小时',
            ),
            subtitle: Text(
              isEnglish
                  ? 'Default span is 07:00–22:00; expands to 00:00–24:00 if any course falls outside'
                  : '常驻跨度为 07:00–22:00；若存在早于 7 点或晚于 22 点的课程则自动扩展为 00:00–24:00',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            value: autoExpandTo24Hours,
            onChanged: onAutoExpandTo24HoursChanged,
          ),
          // 1. 课表时间轴上的当前时间红线指示器
          SwitchListTile(
            secondary: const Icon(Icons.timeline, color: Colors.redAccent),
            title: Text(
              isEnglish ? 'Live Current Time Red Line' : '显示当前时间轴红线指示器',
            ),
            subtitle: Text(
              isEnglish
                  ? 'Draw a live red line & time badge on the time grid'
                  : '在课表时间轴上实时绘制当前时间红线与时间标签',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            value: enableLiveTimeIndicator,
            onChanged: onLiveTimeIndicatorChanged,
          ),
          // 2. 今日所在列专属高亮与具体日期表头
          SwitchListTile(
            secondary: const Icon(Icons.today, color: Colors.blueAccent),
            title: Text(
              isEnglish
                  ? 'Highlight Today Column & Show Dates'
                  : '高亮「今天」所在列并显示月/日日期',
            ),
            subtitle: Text(
              isEnglish
                  ? 'Highlight current weekday column and show exact dates (e.g. 10/15)'
                  : '在星期表头下方显示具体月/日（如 10/15），并高亮标记今天所在列',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            value: highlightTodayColumn,
            onChanged: onHighlightTodayColumnChanged,
          ),
          // 3. 根据开学第一周日期自动推算当前第几周
          SwitchListTile(
            secondary: const Icon(Icons.auto_mode, color: Colors.green),
            title: Text(
              isEnglish
                  ? 'Auto-Calculate Current Teaching Week'
                  : '根据开学日期自动定位当前第几周',
            ),
            subtitle: Text(
              isEnglish
                  ? 'Automatically locates to Week $autoWeek based on system date'
                  : '根据系统当前日期自动推算并定位至本周（当前推算为：第 $autoWeek 周）',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            value: autoCalculateWeek,
            onChanged: onAutoCalculateWeekChanged,
          ),
          if (autoCalculateWeek)
            ListTile(
              leading: const Icon(
                Icons.edit_calendar_outlined,
                color: Colors.green,
              ),
              title: Text(
                isEnglish ? 'Semester Week 1 Monday Date' : '设置开学第 1 周周一日期',
              ),
              subtitle: Text(
                isEnglish
                    ? 'Current base: ${formatDateKey(semesterStartMonday)}'
                    : '当前基准日：${formatDateKey(semesterStartMonday)}（点击可修改校准）',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async {
                final picked = await showDatePicker(
                  context: context,
                  initialDate: semesterStartMonday,
                  firstDate: DateTime(2024),
                  lastDate: DateTime(2030),
                );
                if (picked != null) {
                  onSemesterStartMondayChanged(picked);
                }
              },
            ),
          const Divider(),
          SwitchListTile(
            secondary: const Icon(Icons.compress),
            title: Text(
              isEnglish ? 'Compact / Simple Mode' : '简洁模式（切换简洁/完整视图）',
            ),
            subtitle: Text(
              isEnglish
                  ? 'Hide secondary info in timetable cards for a cleaner look'
                  : '隐藏卡片中的次要文字信息，仅保留核心课程名与起止时间',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            value: isSimpleMode,
            onChanged: onSimpleModeChanged,
          ),
          const Divider(),
          SwitchListTile(
            secondary: const Icon(Icons.event_available_outlined),
            title: Text(
              isEnglish ? 'Show Non-Current Week Courses' : '显示非本周课程',
            ),
            subtitle: Text(
              isEnglish
                  ? 'Display courses from other weeks in a dimmed style'
                  : '在当前周课表中以半透明样式展示其他周的课程',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            value: showNonCurrentWeek,
            onChanged: onShowNonCurrentWeekChanged,
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
                      isEnglish
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
                    bool isSelected = visibleWeekdays.contains(day);
                    return FilterChip(
                      label: Text(getWeekdayLabel(day, isEnglish)),
                      selected: isSelected,
                      onSelected: (val) {
                        final next = List<int>.from(visibleWeekdays);
                        if (val) {
                          next.add(day);
                        } else if (next.length > 1) {
                          next.remove(day);
                        }
                        onVisibleWeekdaysChanged(next);
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
                          isEnglish ? 'Columns per Screen' : '同屏展示天数（列数）',
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                    Text(
                      '$columnsCount ${isEnglish ? 'Days' : '天'}',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Colors.blueAccent,
                      ),
                    ),
                  ],
                ),
                Slider(
                  value: columnsCount.toDouble().clamp(
                    1,
                    visibleWeekdays.length.toDouble(),
                  ),
                  min: 1,
                  max: visibleWeekdays.length.toDouble(),
                  divisions: visibleWeekdays.length > 1
                      ? visibleWeekdays.length - 1
                      : 1,
                  label: '$columnsCount',
                  onChanged: (val) => onColumnsCountChanged(val.toInt()),
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
                          isEnglish ? 'Hour Slot Height' : '每小时时间格高度',
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                    Text(
                      '${hourHeight.toInt()} px',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Colors.blueAccent,
                      ),
                    ),
                  ],
                ),
                Slider(
                  value: hourHeight,
                  min: 60.0,
                  max: 120.0,
                  divisions: 6,
                  onChanged: onHourHeightChanged,
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

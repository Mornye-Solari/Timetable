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
// 全局双端同步与 Excel 自动识别解析引擎
// ============================================================================
class CourseSyncController extends ChangeNotifier {
  List<Course> _courses = [];
  List<Course> get courses => List.unmodifiable(_courses);

  // 内置你上传的 timetable-49898680.xls 原始数据，支持一键解析与自动恢复
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

    if (!kIsWeb) {
      try {
        final Map<String, Course> merged = {for (final c in _courses) c.id: c};
        for (int w = 1; w <= 20; w++) {
          for (final c in getCoursesForWeek(week: w)) {
            // 保留 Rust 侧新增的自定义课程
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

  // 生成用于双端快速同步的 JSON 串
  String exportToSyncJson() {
    final list = _courses
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
    return jsonEncode(list);
  }

  int importFromSyncJson(String jsonStr, {bool replaceAll = true}) {
    final decoded = jsonDecode(jsonStr) as List<dynamic>;
    final List<Course> result = [];
    for (final item in decoded) {
      final m = item as Map<String, dynamic>;
      result.add(
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
    importCourses(result, replaceAll: replaceAll);
    return result.length;
  }

  /// 智能解析 Excel 表格文本（支持 TSV / CSV / 教务系统导出格式）
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
      "#3F51B5", // 靛蓝
      "#009688", // 蓝绿
      "#E91E63", // 玫红
      "#FF9800", // 琥珀橙
      "#9C27B0", // 紫罗兰
      "#00BCD4", // 青色
    ];
    int colorIdx = 0;

    final List<Course> parsed = [];
    int startRow = 0;

    // 跳过表头行
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

      // 对应列: Subject Code(0), Description(1), Group(2), Activity(3), Day(4), Time(5), Campus(6), Location(7), Staff(8), Duration(9), Dates(10)
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

      // 提取课程短代码，如 COMP1100_S2_2026... -> COMP1100
      final shortCode = rawSubjectCode.split('_').first;
      if (!subjectColorMap.containsKey(shortCode)) {
        subjectColorMap[shortCode] = palette[colorIdx % palette.length];
        colorIdx++;
      }
      final courseColor = subjectColorMap[shortCode]!;

      // 解析星期
      int weekday = _parseWeekday(dayStr);

      // 解析持续小时数并推算结束时间
      final durationMatch = RegExp(r'(\d+)').firstMatch(durationStr);
      final int durationHours = durationMatch != null
          ? int.parse(durationMatch.group(1)!)
          : 1;
      final String startTime = _normalizeTime(timeStr);
      final String endTime = _addHoursToTime(startTime, durationHours);

      // 解析教师姓名
      final String teacher = (staffStr == '-' || staffStr.isEmpty)
          ? 'TBA'
          : staffStr;

      // 组合课程名与备注
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
    if (lower.startsWith('mon') || lower.contains('一')) return 1;
    if (lower.startsWith('tue') || lower.contains('二')) return 2;
    if (lower.startsWith('wed') || lower.contains('三')) return 3;
    if (lower.startsWith('thu') || lower.contains('四')) return 4;
    if (lower.startsWith('fri') || lower.contains('五')) return 5;
    if (lower.startsWith('sat') || lower.contains('六')) return 6;
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

// 多语言动态翻译映射
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
  if (name == '软件工程课') return 'Software Engineering';
  if (name == '高级算法') return 'Advanced Algorithms';
  return name;
}

String trLocation(String loc, bool isEn) {
  if (!isEn && loc == 'Delayed viewing (Clashable)') {
    return '录播回放 (允许冲突)';
  }
  if (isEn && loc == '教学楼 A302') return 'Building A302';
  if (isEn && loc == '科研楼 B105') return 'Research Bldg B105';
  return loc;
}

String trTeacher(String t, bool isEn) {
  if (!isEn && t == 'TBA') return '待定 (TBA)';
  if (isEn && t == '教授') return 'Professor';
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
// Excel 导入与双端同步弹窗（电脑端与手机端通用）
// ============================================================================
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
                // Tab 1: Excel 自动识别导入
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

                // Tab 2: 双端数据互通同步码
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isEnglish
                          ? 'Generate a sync code on PC Web and paste it on Mobile App (or vice versa) to sync all courses instantly:'
                          : '在电脑网页端或手机端一键复制“同步码”，在另一端粘贴即可实现双端课表数据秒级完整同步：',
                      style: const TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.copy, size: 18),
                        label: Text(
                          isEnglish
                              ? 'Copy Current Timetable Sync Code'
                              : '一键复制当前端同步码',
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
                                      ? 'Synced $count courses!'
                                      : '双端同步成功！已更新 $count 节课程。',
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
  bool _showNonCurrentWeek = false;
  List<int> _visibleWeekdays = [1, 2, 3, 4, 5, 6, 7];
  int _columnsCount = 5;

  void _toggleTheme(ThemeMode mode) => setState(() => _themeMode = mode);
  void _toggleLanguage(bool isEnglish) =>
      setState(() => _isEnglish = isEnglish);
  void _toggleShowNonCurrentWeek(bool val) =>
      setState(() => _showNonCurrentWeek = val);

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
            showNonCurrentWeek: _showNonCurrentWeek,
            onShowNonCurrentWeekChanged: _toggleShowNonCurrentWeek,
            visibleWeekdays: _visibleWeekdays,
            columnsCount: _columnsCount,
            onVisibleWeekdaysChanged: _updateVisibleWeekdays,
            onColumnsCountChanged: _updateColumnsCount,
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
  final bool showNonCurrentWeek;
  final ValueChanged<bool> onShowNonCurrentWeekChanged;
  final List<int> visibleWeekdays;
  final int columnsCount;
  final ValueChanged<List<int>> onVisibleWeekdaysChanged;
  final ValueChanged<int> onColumnsCountChanged;

  const ResponsiveRoot({
    super.key,
    required this.isEnglish,
    required this.onThemeChanged,
    required this.onLanguageChanged,
    required this.currentThemeMode,
    required this.showNonCurrentWeek,
    required this.onShowNonCurrentWeekChanged,
    required this.visibleWeekdays,
    required this.columnsCount,
    required this.onVisibleWeekdaysChanged,
    required this.onColumnsCountChanged,
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
        showNonCurrentWeek: showNonCurrentWeek,
        onShowNonCurrentWeekChanged: onShowNonCurrentWeekChanged,
        visibleWeekdays: visibleWeekdays,
        columnsCount: columnsCount,
        onVisibleWeekdaysChanged: onVisibleWeekdaysChanged,
        onColumnsCountChanged: onColumnsCountChanged,
      );
    } else {
      return MobileMainScreen(
        isEnglish: isEnglish,
        onThemeChanged: onThemeChanged,
        onLanguageChanged: onLanguageChanged,
        currentThemeMode: currentThemeMode,
        showNonCurrentWeek: showNonCurrentWeek,
        onShowNonCurrentWeekChanged: onShowNonCurrentWeekChanged,
        visibleWeekdays: visibleWeekdays,
        columnsCount: columnsCount,
        onVisibleWeekdaysChanged: onVisibleWeekdaysChanged,
        onColumnsCountChanged: onColumnsCountChanged,
      );
    }
  }
}

// ==========================================
// 1. 电脑网页端
// ==========================================
class DesktopLuxuryWorkspace extends StatefulWidget {
  final bool isEnglish;
  final ValueChanged<ThemeMode> onThemeChanged;
  final ValueChanged<bool> onLanguageChanged;
  final ThemeMode currentThemeMode;
  final bool showNonCurrentWeek;
  final ValueChanged<bool> onShowNonCurrentWeekChanged;
  final List<int> visibleWeekdays;
  final int columnsCount;
  final ValueChanged<List<int>> onVisibleWeekdaysChanged;
  final ValueChanged<int> onColumnsCountChanged;

  const DesktopLuxuryWorkspace({
    super.key,
    required this.isEnglish,
    required this.onThemeChanged,
    required this.onLanguageChanged,
    required this.currentThemeMode,
    required this.showNonCurrentWeek,
    required this.onShowNonCurrentWeekChanged,
    required this.visibleWeekdays,
    required this.columnsCount,
    required this.onVisibleWeekdaysChanged,
    required this.onColumnsCountChanged,
  });

  @override
  State<DesktopLuxuryWorkspace> createState() => _DesktopLuxuryWorkspaceState();
}

class _DesktopLuxuryWorkspaceState extends State<DesktopLuxuryWorkspace> {
  String _viewMode = 'Week';
  int _currentWeek = 11; // 对应 13/10 - 15/10 所在教学周
  Course? _selectedCourse;

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

    return Scaffold(
      backgroundColor: bgCol,
      body: Row(
        children: [
          Container(
            width: 280,
            color: cardBg,
            padding: const EdgeInsets.all(24),
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
                const SizedBox(height: 28),
                _buildSidebarItem(
                  Icons.grid_view_rounded,
                  widget.isEnglish ? 'Timetable' : '课表视图',
                  true,
                ),
                _buildSidebarItem(
                  Icons.calendar_month_outlined,
                  widget.isEnglish ? 'Schedule' : '日程安排',
                  false,
                ),
                const Divider(height: 28),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text(
                    widget.isEnglish ? 'Show Non-Current Week' : '显示非本周课程',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  value: widget.showNonCurrentWeek,
                  onChanged: widget.onShowNonCurrentWeekChanged,
                ),
                const SizedBox(height: 12),
                Text(
                  widget.isEnglish ? 'Displayed Days' : '显示星期 (过滤无课日)',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Colors.grey,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: List.generate(7, (index) {
                    int day = index + 1;
                    bool isSelected = widget.visibleWeekdays.contains(day);
                    return FilterChip(
                      label: Text(
                        getWeekdayLabel(day, widget.isEnglish),
                        style: const TextStyle(fontSize: 11),
                      ),
                      selected: isSelected,
                      visualDensity: VisualDensity.compact,
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
                const SizedBox(height: 16),
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
                  onChanged: (val) => widget.onColumnsCountChanged(val.toInt()),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  margin: const EdgeInsets.only(bottom: 12),
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
                    vertical: 6,
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
          Expanded(
            flex: 3,
            child: Padding(
              padding: const EdgeInsets.all(32.0),
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
                            child: Text(
                              widget.isEnglish
                                  ? 'Week $_currentWeek'
                                  : '第 $_currentWeek 周',
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
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
                  const SizedBox(height: 24),
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.all(24),
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
                          ? _buildMonthView()
                          : _viewMode == 'Week'
                          ? _buildWeekView(selected)
                          : _buildDayView(),
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
                        if (!_isCourseActiveInWeek(selected, _currentWeek)) ...[
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
                                color: Colors.redAccent.withValues(alpha: 0.3),
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
      ),
    );
  }

  Widget _buildSidebarItem(IconData icon, String label, bool active) =>
      Container(
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: active
              ? Colors.blueAccent.withValues(alpha: 0.1)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: ListTile(
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

  Widget _buildWeekView(Course? selected) {
    final visible = _visibleCourses;
    final days = widget.visibleWeekdays;
    final showRichText = widget.columnsCount <= 4;

    return LayoutBuilder(
      builder: (context, constraints) {
        final colWidth = (constraints.maxWidth / widget.columnsCount).clamp(
          120.0,
          500.0,
        );
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            height: constraints.maxHeight,
            child: Row(
              children: days.map((dayIndex) {
                final dayCourses =
                    visible.where((c) => c.weekday == dayIndex).toList()
                      ..sort((a, b) => a.startTime.compareTo(b.startTime));
                return Container(
                  width: colWidth - 8,
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.grey.withValues(alpha: 0.03),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: Colors.grey.withValues(alpha: 0.08),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        getWeekdayLabel(dayIndex, widget.isEnglish),
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                      const Divider(),
                      if (dayCourses.isEmpty)
                        Expanded(
                          child: Center(
                            child: Text(
                              '-',
                              style: TextStyle(
                                color: Colors.grey.withValues(alpha: 0.3),
                              ),
                            ),
                          ),
                        )
                      else
                        Expanded(
                          child: ListView(
                            children: dayCourses.map((c) {
                              bool isSelected = selected?.id == c.id;
                              bool isCurrentWeek = _isCourseActiveInWeek(
                                c,
                                _currentWeek,
                              );
                              final cColor = isCurrentWeek
                                  ? parseHexColor(c.color)
                                  : Colors.grey;

                              return Opacity(
                                opacity: isCurrentWeek ? 1.0 : 0.55,
                                child: InkWell(
                                  onTap: () =>
                                      setState(() => _selectedCourse = c),
                                  child: Container(
                                    margin: const EdgeInsets.symmetric(
                                      vertical: 4,
                                    ),
                                    padding: const EdgeInsets.all(10),
                                    decoration: BoxDecoration(
                                      color: isSelected
                                          ? cColor.withValues(alpha: 0.28)
                                          : cColor.withValues(alpha: 0.12),
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border.all(
                                        color: isSelected
                                            ? cColor
                                            : cColor.withValues(alpha: 0.3),
                                        width: isSelected ? 2 : 1,
                                      ),
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        if (!isCurrentWeek)
                                          Padding(
                                            padding: const EdgeInsets.only(
                                              bottom: 2,
                                            ),
                                            child: Text(
                                              widget.isEnglish
                                                  ? '[Inactive]'
                                                  : '[非本周]',
                                              style: const TextStyle(
                                                fontSize: 10,
                                                fontWeight: FontWeight.bold,
                                                color: Colors.orange,
                                              ),
                                            ),
                                          ),
                                        Text(
                                          trName(c.name, widget.isEnglish),
                                          style: const TextStyle(
                                            fontWeight: FontWeight.bold,
                                            fontSize: 13,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          '${c.startTime} - ${c.endTime}',
                                          style: const TextStyle(
                                            fontSize: 11,
                                            color: Colors.grey,
                                          ),
                                        ),
                                        Text(
                                          trLocation(
                                            c.location,
                                            widget.isEnglish,
                                          ),
                                          style: const TextStyle(
                                            fontSize: 11,
                                            color: Colors.grey,
                                          ),
                                        ),
                                        if (showRichText) ...[
                                          const Divider(height: 10),
                                          Text(
                                            '${trTeacher(c.teacher, widget.isEnglish)} · ${c.credits} Cr',
                                            style: const TextStyle(
                                              fontSize: 11,
                                            ),
                                          ),
                                          if (c.remark.isNotEmpty)
                                            Text(
                                              trRemark(
                                                c.remark,
                                                widget.isEnglish,
                                              ),
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                fontSize: 10,
                                                color: Colors.blueAccent,
                                              ),
                                            ),
                                        ],
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            }).toList(),
                          ),
                        ),
                    ],
                  ),
                );
              }).toList(),
            ),
          ),
        );
      },
    );
  }

  Widget _buildDayView() => Center(
    child: Text(
      widget.isEnglish ? 'Day View' : '日视图',
      style: const TextStyle(color: Colors.grey),
    ),
  );

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

// ==========================================
// 2. 手机端
// ==========================================
class MobileMainScreen extends StatefulWidget {
  final bool isEnglish;
  final ValueChanged<ThemeMode> onThemeChanged;
  final ValueChanged<bool> onLanguageChanged;
  final ThemeMode currentThemeMode;
  final bool showNonCurrentWeek;
  final ValueChanged<bool> onShowNonCurrentWeekChanged;
  final List<int> visibleWeekdays;
  final int columnsCount;
  final ValueChanged<List<int>> onVisibleWeekdaysChanged;
  final ValueChanged<int> onColumnsCountChanged;

  const MobileMainScreen({
    super.key,
    required this.isEnglish,
    required this.onThemeChanged,
    required this.onLanguageChanged,
    required this.currentThemeMode,
    required this.showNonCurrentWeek,
    required this.onShowNonCurrentWeekChanged,
    required this.visibleWeekdays,
    required this.columnsCount,
    required this.onVisibleWeekdaysChanged,
    required this.onColumnsCountChanged,
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
        showNonCurrentWeek: widget.showNonCurrentWeek,
        visibleWeekdays: widget.visibleWeekdays,
        columnsCount: widget.columnsCount,
      ),
      ProfilePage(
        isEnglish: widget.isEnglish,
        onThemeChanged: widget.onThemeChanged,
        onLanguageChanged: widget.onLanguageChanged,
        currentThemeMode: widget.currentThemeMode,
        showNonCurrentWeek: widget.showNonCurrentWeek,
        onShowNonCurrentWeekChanged: widget.onShowNonCurrentWeekChanged,
        visibleWeekdays: widget.visibleWeekdays,
        columnsCount: widget.columnsCount,
        onVisibleWeekdaysChanged: widget.onVisibleWeekdaysChanged,
        onColumnsCountChanged: widget.onColumnsCountChanged,
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

class SchedulePage extends StatelessWidget {
  final bool isEnglish;
  const SchedulePage({super.key, required this.isEnglish});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        isEnglish ? 'Schedule (Daily Events)' : '日程（单日/未来事件编辑）',
        style: const TextStyle(fontSize: 18, color: Colors.grey),
      ),
    );
  }
}

class MobileTimetablePage extends StatefulWidget {
  final bool isEnglish;
  final bool showNonCurrentWeek;
  final List<int> visibleWeekdays;
  final int columnsCount;

  const MobileTimetablePage({
    super.key,
    required this.isEnglish,
    required this.showNonCurrentWeek,
    required this.visibleWeekdays,
    required this.columnsCount,
  });

  @override
  State<MobileTimetablePage> createState() => _MobileTimetablePageState();
}

class _MobileTimetablePageState extends State<MobileTimetablePage> {
  int _week = 11;

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
    final visible = _visibleCourses;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final showRichDetail = widget.columnsCount <= 3;

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
            Text(
              widget.isEnglish ? 'Week $_week' : '第 $_week 周',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            IconButton(
              icon: const Icon(Icons.chevron_right, size: 22),
              onPressed: () {
                if (_week < 20) {
                  setState(() => _week++);
                }
              },
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
      body: LayoutBuilder(
        builder: (context, constraints) {
          final colWidth = constraints.maxWidth / widget.columnsCount;
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              height: constraints.maxHeight,
              child: Row(
                children: widget.visibleWeekdays.map((dayIndex) {
                  final dayCourses =
                      visible.where((c) => c.weekday == dayIndex).toList()
                        ..sort((a, b) => a.startTime.compareTo(b.startTime));

                  return Container(
                    width: colWidth - 8,
                    margin: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: isDark
                          ? Colors.grey.shade900
                          : Colors.grey.shade100,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(10.0),
                          child: Text(
                            getWeekdayLabel(dayIndex, widget.isEnglish),
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                        const Divider(height: 1),
                        Expanded(
                          child: dayCourses.isEmpty
                              ? Center(
                                  child: Text(
                                    '-',
                                    style: TextStyle(
                                      color: Colors.grey.withValues(alpha: 0.3),
                                    ),
                                  ),
                                )
                              : ListView(
                                  padding: const EdgeInsets.all(6),
                                  children: dayCourses.map((c) {
                                    final isCurrentWeek = _isCourseActiveInWeek(
                                      c,
                                      _week,
                                    );
                                    final cColor = isCurrentWeek
                                        ? parseHexColor(c.color)
                                        : Colors.grey;

                                    return Opacity(
                                      opacity: isCurrentWeek ? 1.0 : 0.55,
                                      child: InkWell(
                                        onTap: () => _showCourseDetail(c),
                                        child: Container(
                                          margin: const EdgeInsets.only(
                                            bottom: 8,
                                          ),
                                          padding: const EdgeInsets.all(8),
                                          decoration: BoxDecoration(
                                            color: cColor.withValues(
                                              alpha: 0.15,
                                            ),
                                            borderRadius: BorderRadius.circular(
                                              10,
                                            ),
                                            border: Border.all(
                                              color: cColor.withValues(
                                                alpha: 0.35,
                                              ),
                                            ),
                                          ),
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              if (!isCurrentWeek)
                                                Padding(
                                                  padding:
                                                      const EdgeInsets.only(
                                                        bottom: 2,
                                                      ),
                                                  child: Text(
                                                    widget.isEnglish
                                                        ? '[Inactive]'
                                                        : '[非本周]',
                                                    style: const TextStyle(
                                                      fontSize: 10,
                                                      fontWeight:
                                                          FontWeight.bold,
                                                      color: Colors.orange,
                                                    ),
                                                  ),
                                                ),
                                              Text(
                                                trName(
                                                  c.name,
                                                  widget.isEnglish,
                                                ),
                                                style: TextStyle(
                                                  fontWeight: FontWeight.bold,
                                                  fontSize: showRichDetail
                                                      ? 13
                                                      : 11,
                                                ),
                                              ),
                                              const SizedBox(height: 4),
                                              Text(
                                                showRichDetail
                                                    ? '${c.startTime} - ${c.endTime}'
                                                    : c.startTime,
                                                style: const TextStyle(
                                                  fontSize: 11,
                                                  color: Colors.grey,
                                                ),
                                              ),
                                              Text(
                                                trLocation(
                                                  c.location,
                                                  widget.isEnglish,
                                                ),
                                                maxLines: showRichDetail
                                                    ? 2
                                                    : 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  fontSize: 10,
                                                  color: Colors.grey,
                                                ),
                                              ),
                                              if (showRichDetail) ...[
                                                const Divider(height: 10),
                                                Text(
                                                  trTeacher(
                                                    c.teacher,
                                                    widget.isEnglish,
                                                  ),
                                                  style: const TextStyle(
                                                    fontSize: 10,
                                                    fontWeight: FontWeight.w500,
                                                  ),
                                                ),
                                                if (c.remark.isNotEmpty)
                                                  Padding(
                                                    padding:
                                                        const EdgeInsets.only(
                                                          top: 2,
                                                        ),
                                                    child: Text(
                                                      trRemark(
                                                        c.remark,
                                                        widget.isEnglish,
                                                      ),
                                                      maxLines: 2,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      style: const TextStyle(
                                                        fontSize: 9,
                                                        color:
                                                            Colors.blueAccent,
                                                      ),
                                                    ),
                                                  ),
                                              ],
                                            ],
                                          ),
                                        ),
                                      ),
                                    );
                                  }).toList(),
                                ),
                        ),
                      ],
                    ),
                  );
                }).toList(),
              ),
            ),
          );
        },
      ),
    );
  }
}

// ==========================================
// 3. 添加/编辑课程表单 (双端复用)
// ==========================================
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

// ==========================================
// 4. 我的与设置
// ==========================================
class ProfilePage extends StatelessWidget {
  final bool isEnglish;
  final ValueChanged<ThemeMode> onThemeChanged;
  final ValueChanged<bool> onLanguageChanged;
  final ThemeMode currentThemeMode;
  final bool showNonCurrentWeek;
  final ValueChanged<bool> onShowNonCurrentWeekChanged;
  final List<int> visibleWeekdays;
  final int columnsCount;
  final ValueChanged<List<int>> onVisibleWeekdaysChanged;
  final ValueChanged<int> onColumnsCountChanged;

  const ProfilePage({
    super.key,
    required this.isEnglish,
    required this.onThemeChanged,
    required this.onLanguageChanged,
    required this.currentThemeMode,
    required this.showNonCurrentWeek,
    required this.onShowNonCurrentWeekChanged,
    required this.visibleWeekdays,
    required this.columnsCount,
    required this.onVisibleWeekdaysChanged,
    required this.onColumnsCountChanged,
  });

  @override
  Widget build(BuildContext context) {
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
                const SizedBox(height: 4),
                Text(
                  isEnglish
                      ? 'Fewer columns (≤3) automatically display full teacher, credits, and remark details.'
                      : '当同屏展示天数较少（≤3天）时，单列变宽并自动显示任课老师、学分与备注等完整信息。',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
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
        ],
      ),
    );
  }
}

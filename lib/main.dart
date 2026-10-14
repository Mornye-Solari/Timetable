import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
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
  runApp(const MyApp());
}

String trName(String name, bool isEn) =>
    (isEn && name == '软件工程课') ? 'Software Engineering' : name;
String trLocation(String loc, bool isEn) =>
    (isEn && loc == '教学楼 A302') ? 'Building A302' : loc;
String trTeacher(String t, bool isEn) => (isEn && t == '教授') ? 'Professor' : t;
String trRemark(String r, bool isEn) =>
    (isEn && r == '记得带电脑') ? 'Remember to bring laptop' : r;

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

List<Course> globalMockCourses = [
  Course(
    id: "1",
    name: "软件工程课",
    color: "#3F51B5",
    credits: 3.0,
    startWeek: 1,
    endWeek: 16,
    weekday: 4,
    totalSections: 2,
    hasBreak: true,
    startTime: "08:00",
    endTime: "09:40",
    location: "教学楼 A302",
    teacher: "教授",
    remark: "记得带电脑",
    enableReminder: true,
    reminderMinutes: 15,
    reminderCount: 1,
  ),
];

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  ThemeMode _themeMode = ThemeMode.system;
  bool _isEnglish = false;

  // 第 12 条：自定义显示的星期列表（默认周一至周日全显示）
  List<int> _visibleWeekdays = [1, 2, 3, 4, 5, 6, 7];
  // 第 13 条：同屏展示的列数（当列数少时，单列更宽，自动展示更多课程细节文字）
  int _columnsCount = 5;

  void _toggleTheme(ThemeMode mode) => setState(() => _themeMode = mode);
  void _toggleLanguage(bool isEnglish) =>
      setState(() => _isEnglish = isEnglish);

  void _updateVisibleWeekdays(List<int> days) {
    if (days.isEmpty) {
      return; // 至少保留一天
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
        visibleWeekdays: _visibleWeekdays,
        columnsCount: _columnsCount,
        onVisibleWeekdaysChanged: _updateVisibleWeekdays,
        onColumnsCountChanged: _updateColumnsCount,
      ),
    );
  }
}

class ResponsiveRoot extends StatelessWidget {
  final bool isEnglish;
  final ValueChanged<ThemeMode> onThemeChanged;
  final ValueChanged<bool> onLanguageChanged;
  final ThemeMode currentThemeMode;
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
  int _currentWeek = 7;
  Course? _selectedCourse;
  List<Course> _allCourses = [];

  @override
  void initState() {
    super.initState();
    _fetchData();
  }

  void _fetchData() {
    setState(() {
      if (kIsWeb) {
        _allCourses = List.from(globalMockCourses);
      } else {
        try {
          _allCourses = getCoursesForWeek(week: _currentWeek);
        } catch (_) {
          _allCourses = [];
        }
      }
      _checkSelection();
    });
  }

  List<Course> get _visibleCourses => _allCourses
      .where((c) => _currentWeek >= c.startWeek && _currentWeek <= c.endWeek)
      .toList();

  void _checkSelection() {
    final visible = _visibleCourses;
    if (visible.isNotEmpty) {
      if (_selectedCourse == null ||
          !visible.any((c) => c.id == _selectedCourse!.id)) {
        _selectedCourse = visible.first;
      } else {
        _selectedCourse = visible.firstWhere(
          (c) => c.id == _selectedCourse!.id,
        );
      }
    } else {
      _selectedCourse = null;
    }
  }

  void _deleteSelectedCourse() {
    if (_selectedCourse == null) {
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
              setState(() {
                _allCourses.removeWhere((c) => c.id == _selectedCourse!.id);
                if (kIsWeb) {
                  globalMockCourses = List.from(_allCourses);
                }
                _checkSelection();
              });
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
    if (_selectedCourse == null) {
      return;
    }
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => AddCoursePage(
          isEnglish: widget.isEnglish,
          courseToEdit: _selectedCourse,
        ),
      ),
    );
    if (result != null && result is Course) {
      setState(() {
        final index = _allCourses.indexWhere((c) => c.id == result.id);
        if (index != -1) {
          _allCourses[index] = result;
          _selectedCourse = result;
        }
        if (kIsWeb) {
          globalMockCourses = List.from(_allCourses);
        }
        _checkSelection();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgCol = isDark ? const Color(0xFF121212) : const Color(0xFFF8F9FA);
    final cardBg = isDark ? const Color(0xFF1E1E1E) : Colors.white;
    final borderCol = isDark ? Colors.white12 : Colors.black12;

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
                const SizedBox(height: 32),
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
                const Divider(height: 32),
                // 第 12 条：电脑端快捷过滤显示的星期
                Text(
                  widget.isEnglish ? 'Displayed Days' : '显示星期 (过滤无课日)',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Colors.grey,
                  ),
                ),
                const SizedBox(height: 10),
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
                const SizedBox(height: 20),
                // 第 13 条：控制同屏展示列数
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
                                setState(() {
                                  _currentWeek--;
                                  _checkSelection();
                                });
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
                                setState(() {
                                  _currentWeek++;
                                  _checkSelection();
                                });
                              }
                            },
                          ),
                          const SizedBox(width: 16),
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
                                setState(() {
                                  _allCourses.add(result);
                                  if (kIsWeb) {
                                    globalMockCourses = List.from(_allCourses);
                                  }
                                  _checkSelection();
                                });
                              }
                            },
                            icon: const Icon(Icons.add, size: 18),
                            label: Text(
                              widget.isEnglish ? 'Add Course' : '添加课程',
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
                          ? _buildWeekView()
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
              child: _selectedCourse == null
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
                                color: parseHexColor(_selectedCourse!.color),
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                trName(_selectedCourse!.name, widget.isEnglish),
                                style: const TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 20),
                        _buildDetailRow(
                          Icons.calendar_today,
                          widget.isEnglish ? 'Day' : '星期',
                          getWeekdayLabel(
                            _selectedCourse!.weekday,
                            widget.isEnglish,
                          ),
                        ),
                        _buildDetailRow(
                          Icons.access_time,
                          widget.isEnglish ? 'Time' : '时间',
                          '${_selectedCourse!.startTime} - ${_selectedCourse!.endTime}',
                        ),
                        _buildDetailRow(
                          Icons.star_border,
                          widget.isEnglish ? 'Credits' : '学分',
                          '${_selectedCourse!.credits} Cr',
                        ),
                        _buildDetailRow(
                          Icons.person_outline,
                          widget.isEnglish ? 'Teacher' : '教师',
                          trTeacher(_selectedCourse!.teacher, widget.isEnglish),
                        ),
                        _buildDetailRow(
                          Icons.date_range,
                          widget.isEnglish ? 'Weeks' : '周数',
                          widget.isEnglish
                              ? 'Weeks ${_selectedCourse!.startWeek} - ${_selectedCourse!.endWeek}'
                              : '第 ${_selectedCourse!.startWeek} - ${_selectedCourse!.endWeek} 周',
                        ),
                        if (_selectedCourse!.remark.isNotEmpty) ...[
                          _buildDetailRow(
                            Icons.notes,
                            widget.isEnglish ? 'Remark' : '备注',
                            trRemark(_selectedCourse!.remark, widget.isEnglish),
                          ),
                        ],
                        const SizedBox(height: 20),
                        InkWell(
                          onTap: () async {
                            final query = Uri.encodeComponent(
                              trLocation(
                                _selectedCourse!.location,
                                widget.isEnglish,
                              ),
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
                                            ? 'Location (Map)'
                                            : '上课教室导航',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 12,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        trLocation(
                                          _selectedCourse!.location,
                                          widget.isEnglish,
                                        ),
                                        style: const TextStyle(fontSize: 14),
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

  Widget _buildWeekView() {
    final visible = _visibleCourses;
    final days = widget.visibleWeekdays;
    // 当同屏展示列数较少（<= 4 列）时，开启丰富信息模式，展示老师、学分与备注
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
                final dayCourses = visible
                    .where((c) => c.weekday == dayIndex)
                    .toList();
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
                              bool isSelected = _selectedCourse == c;
                              final cColor = parseHexColor(c.color);
                              return InkWell(
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
                                          style: const TextStyle(fontSize: 11),
                                        ),
                                        Text(
                                          widget.isEnglish
                                              ? 'Weeks ${c.startWeek}-${c.endWeek}'
                                              : '第 ${c.startWeek}-${c.endWeek} 周',
                                          style: const TextStyle(
                                            fontSize: 10,
                                            color: Colors.grey,
                                          ),
                                        ),
                                        if (c.remark.isNotEmpty)
                                          Text(
                                            trRemark(
                                              c.remark,
                                              widget.isEnglish,
                                            ),
                                            style: const TextStyle(
                                              fontSize: 10,
                                              fontStyle: FontStyle.italic,
                                              color: Colors.blueAccent,
                                            ),
                                          ),
                                      ],
                                    ],
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
                  children: dayCourses
                      .map(
                        (c) => Container(
                          margin: const EdgeInsets.only(bottom: 2),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: parseHexColor(c.color)
                                .withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            trName(c.name, widget.isEnglish),
                            style: TextStyle(
                              fontSize: 10,
                              color: parseHexColor(c.color),
                              fontWeight: FontWeight.bold,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      )
                      .toList(),
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
        visibleWeekdays: widget.visibleWeekdays,
        columnsCount: widget.columnsCount,
      ),
      ProfilePage(
        isEnglish: widget.isEnglish,
        onThemeChanged: widget.onThemeChanged,
        onLanguageChanged: widget.onLanguageChanged,
        currentThemeMode: widget.currentThemeMode,
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
  final List<int> visibleWeekdays;
  final int columnsCount;

  const MobileTimetablePage({
    super.key,
    required this.isEnglish,
    required this.visibleWeekdays,
    required this.columnsCount,
  });

  @override
  State<MobileTimetablePage> createState() => _MobileTimetablePageState();
}

class _MobileTimetablePageState extends State<MobileTimetablePage> {
  int _week = 7;
  List<Course> _allCourses = [];

  @override
  void initState() {
    super.initState();
    _fetchData();
  }

  void _fetchData() {
    setState(() {
      if (kIsWeb) {
        _allCourses = List.from(globalMockCourses);
      } else {
        try {
          _allCourses = getCoursesForWeek(week: _week);
        } catch (_) {
          _allCourses = [];
        }
      }
    });
  }

  List<Course> get _visibleCourses => _allCourses
      .where((c) => _week >= c.startWeek && _week <= c.endWeek)
      .toList();

  Future<void> _editCourse(Course course) async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) =>
            AddCoursePage(isEnglish: widget.isEnglish, courseToEdit: course),
      ),
    );
    if (result != null && result is Course) {
      setState(() {
        final index = _allCourses.indexWhere((c) => c.id == result.id);
        if (index != -1) {
          _allCourses[index] = result;
        }
        if (kIsWeb) {
          globalMockCourses = List.from(_allCourses);
        }
      });
    }
  }

  void _showCourseDetail(Course course) {
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
                        fontSize: 22,
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
                      setState(() {
                        _allCourses.removeWhere((c) => c.id == course.id);
                        if (kIsWeb) {
                          globalMockCourses = List.from(_allCourses);
                        }
                      });
                      Navigator.pop(context);
                    },
                  ),
                ],
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
                    trLocation(course.location, widget.isEnglish),
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
              const SizedBox(height: 20),
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
    // 第 13 条：当设置的展示列数 <= 3 列时，单列宽度充裕，直接展示任课老师、学分、周数与备注等详细文字信息
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
            icon: const Icon(Icons.add),
            onPressed: () async {
              final result = await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) =>
                      AddCoursePage(isEnglish: widget.isEnglish),
                ),
              );
              if (result != null && result is Course) {
                setState(() {
                  _allCourses.add(result);
                  if (kIsWeb) {
                    globalMockCourses = List.from(_allCourses);
                  }
                });
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
                  final dayCourses = visible
                      .where((c) => c.weekday == dayIndex)
                      .toList();

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
                                    final cColor = parseHexColor(c.color);
                                    return InkWell(
                                      onTap: () => _showCourseDetail(c),
                                      child: Container(
                                        margin: const EdgeInsets.only(
                                          bottom: 8,
                                        ),
                                        padding: const EdgeInsets.all(8),
                                        decoration: BoxDecoration(
                                          color: cColor.withValues(alpha: 0.15),
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
                                            Text(
                                              trName(c.name, widget.isEnglish),
                                              style: TextStyle(
                                                fontWeight: FontWeight.bold,
                                                fontSize: showRichDetail
                                                    ? 14
                                                    : 12,
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
                                              style: const TextStyle(
                                                fontSize: 11,
                                                color: Colors.grey,
                                              ),
                                            ),
                                            if (showRichDetail) ...[
                                              const Divider(height: 10),
                                              Text(
                                                '${trTeacher(c.teacher, widget.isEnglish)} · ${c.credits} Cr',
                                                style: const TextStyle(
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.w500,
                                                ),
                                              ),
                                              Text(
                                                widget.isEnglish
                                                    ? 'Weeks ${c.startWeek}-${c.endWeek}'
                                                    : '第 ${c.startWeek}-${c.endWeek} 周',
                                                style: const TextStyle(
                                                  fontSize: 10,
                                                  color: Colors.grey,
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
                                                    style: const TextStyle(
                                                      fontSize: 10,
                                                      color: Colors.blueAccent,
                                                    ),
                                                  ),
                                                ),
                                            ],
                                          ],
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
  double _credits = 3.0;
  int _startWeek = 1;
  int _endWeek = 16;
  String _startTime = "08:00";
  String _endTime = "09:40";
  String _selectedColor = "#3F51B5";

  final List<String> _colors = [
    "#3F51B5",
    "#E91E63",
    "#4CAF50",
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
          ? (widget.isEnglish ? 'Building A302' : '教学楼 A302')
          : _locationController.text.trim(),
      teacher: _teacherController.text.trim().isEmpty
          ? (widget.isEnglish ? 'Professor' : '教授')
          : _teacherController.text.trim(),
      remark: _remarkController.text.trim(),
      enableReminder: true,
      reminderMinutes: 15,
      reminderCount: 1,
    );

    if (!kIsWeb && widget.courseToEdit == null) {
      try {
        addCourse(course: newCourse);
      } catch (_) {}
    }
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
// 4. 我的与设置（含第 12、13 条课表显示定制）
// ==========================================
class ProfilePage extends StatelessWidget {
  final bool isEnglish;
  final ValueChanged<ThemeMode> onThemeChanged;
  final ValueChanged<bool> onLanguageChanged;
  final ThemeMode currentThemeMode;
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
              isEnglish ? 'Timetable User' : '课表用户',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(height: 24),
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
          // 第 12 条：设置课表显示的星期
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
          // 第 13 条：设置课表同屏展示的列数
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

import 'package:flutter/material.dart';
import 'package:timetable_app/src/rust/api/simple.dart';
import 'package:timetable_app/src/rust/frb_generated.dart';
import 'package:url_launcher/url_launcher.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  ThemeMode _themeMode = ThemeMode.system;
  bool _isEnglish = false;

  void _toggleTheme(ThemeMode mode) => setState(() => _themeMode = mode);
  void _toggleLanguage(bool isEnglish) =>
      setState(() => _isEnglish = isEnglish);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Timetable',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blueAccent),
        useMaterial3: true,
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blueAccent,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      themeMode: _themeMode,
      home: MainScreen(
        isEnglish: _isEnglish,
        onThemeChanged: _toggleTheme,
        onLanguageChanged: _toggleLanguage,
        currentThemeMode: _themeMode,
      ),
    );
  }
}

class MainScreen extends StatefulWidget {
  final bool isEnglish;
  final ValueChanged<ThemeMode> onThemeChanged;
  final ValueChanged<bool> onLanguageChanged;
  final ThemeMode currentThemeMode;

  const MainScreen({
    super.key,
    required this.isEnglish,
    required this.onThemeChanged,
    required this.onLanguageChanged,
    required this.currentThemeMode,
  });

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _currentIndex = 1;

  @override
  Widget build(BuildContext context) {
    final labels = widget.isEnglish
        ? ['Schedule', 'Timetable', 'Profile']
        : ['日程', '课表', '我的'];

    final pages = [
      SchedulePage(isEnglish: widget.isEnglish),
      TimetablePage(isEnglish: widget.isEnglish),
      ProfilePage(
        isEnglish: widget.isEnglish,
        onThemeChanged: widget.onThemeChanged,
        onLanguageChanged: widget.onLanguageChanged,
        currentThemeMode: widget.currentThemeMode,
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
        isEnglish ? 'Schedule Page (Coming Soon)' : '日程页面（开发中）',
        style: const TextStyle(fontSize: 18, color: Colors.grey),
      ),
    );
  }
}

/// 核心课表页面
class TimetablePage extends StatefulWidget {
  final bool isEnglish;
  const TimetablePage({super.key, required this.isEnglish});

  @override
  State<TimetablePage> createState() => _TimetablePageState();
}

class _TimetablePageState extends State<TimetablePage> {
  List<Course> _courses = [];

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  void _loadData() {
    final list = getCoursesForWeek(week: 7);
    setState(() {
      _courses = list;
    });
  }

  String _getWeekdayLabel(int weekday, bool isEnglish) {
    const zh = ['', '周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    const en = ['', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return isEnglish ? en[weekday] : zh[weekday];
  }

  // 打开课程详情弹窗
  void _showCourseDetail(Course course) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        final displayName = widget.isEnglish && course.name == '软件工程课'
            ? 'Software Engineering'
            : course.name;
        final displayTeacher = widget.isEnglish && course.teacher == '教授'
            ? 'Professor'
            : course.teacher;
        final displayLocation =
            widget.isEnglish && course.location == '教学楼 A302'
            ? 'Building A302'
            : course.location;
        final displayRemark = widget.isEnglish && course.remark == '记得带电脑'
            ? 'Remember to bring laptop'
            : course.remark;

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
                      displayName,
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const Divider(),
              const SizedBox(height: 8),
              ListTile(
                leading: const Icon(
                  Icons.access_time,
                  color: Colors.blueAccent,
                ),
                title: Text(widget.isEnglish ? 'Time & Date' : '上课时间'),
                subtitle: Text(
                  '${_getWeekdayLabel(course.weekday, widget.isEnglish)} ${course.startTime} - ${course.endTime} (${widget.isEnglish ? 'Weeks ' : '第'}${course.startWeek}-${course.endWeek}${widget.isEnglish ? '' : '周'})',
                ),
              ),
              ListTile(
                leading: const Icon(Icons.location_on, color: Colors.redAccent),
                title: Text(
                  widget.isEnglish ? 'Location (Google Map)' : '上课教室 (点击跳转地图)',
                ),
                subtitle: Text(displayLocation),
                trailing: const Icon(Icons.open_in_new, size: 18),
                onTap: () async {
                  final query = Uri.encodeComponent(displayLocation);
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
                title: Text(widget.isEnglish ? 'Teacher' : '任课老师'),
                subtitle: Text(displayTeacher),
              ),
              ListTile(
                leading: const Icon(Icons.star, color: Colors.orange),
                title: Text(widget.isEnglish ? 'Credits' : '学分'),
                subtitle: Text('${course.credits} Cr'),
              ),
              if (displayRemark.isNotEmpty)
                ListTile(
                  leading: const Icon(Icons.note, color: Colors.purple),
                  title: Text(widget.isEnglish ? 'Remark' : '备注'),
                  subtitle: Text(displayRemark),
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
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.isEnglish ? 'Week 7 · Thursday' : '第 7 周 周四',
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
        ),
        elevation: 0,
        actions: [
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
              if (result == true) {
                _loadData();
              }
            },
          ),
        ],
      ),
      body: _courses.isEmpty
          ? Center(
              child: Text(
                widget.isEnglish
                    ? 'No courses, click "+" to add'
                    : '暂无课程，请点击右上角 "+" 添加',
                style: const TextStyle(color: Colors.grey),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: _courses.length,
              itemBuilder: (context, index) {
                final course = _courses[index];
                final displayName = widget.isEnglish && course.name == '软件工程课'
                    ? 'Software Engineering'
                    : course.name;
                final displayTeacher =
                    widget.isEnglish && course.teacher == '教授'
                    ? 'Professor'
                    : course.teacher;
                final displayLocation =
                    widget.isEnglish && course.location == '教学楼 A302'
                    ? 'Building A302'
                    : course.location;

                return InkWell(
                  onTap: () => _showCourseDetail(course),
                  child: Card(
                    elevation: 2,
                    margin: const EdgeInsets.symmetric(vertical: 6),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: ListTile(
                      leading: CircleAvatar(
                        backgroundColor: Colors.blue.shade100,
                        child: Text(
                          _getWeekdayLabel(course.weekday, widget.isEnglish),
                          style: const TextStyle(
                            color: Colors.blueAccent,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      title: Text(
                        displayName,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      subtitle: Text(
                        widget.isEnglish
                            ? 'Time: ${course.startTime} - ${course.endTime}\nLocation: $displayLocation | Teacher: $displayTeacher'
                            : '时间: ${course.startTime} - ${course.endTime}\n地点: $displayLocation | 老师: $displayTeacher',
                      ),
                      isThreeLine: true,
                      trailing: Text('${course.credits} Cr'),
                    ),
                  ),
                );
              },
            ),
    );
  }
}

/// 具备完整交互功能的“添加课程”表单页
class AddCoursePage extends StatefulWidget {
  final bool isEnglish;
  const AddCoursePage({super.key, required this.isEnglish});

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

  Color _parseColor(String hexStr) {
    try {
      return Color(int.parse(hexStr.replaceFirst('#', '0xFF')));
    } catch (_) {
      return Colors.blueAccent;
    }
  }

  void _showCreditsDialog() {
    showDialog(
      context: context,
      builder: (context) {
        double tempCredits = _credits;
        return AlertDialog(
          title: Text(widget.isEnglish ? 'Select Credits' : '选择学分'),
          content: StatefulBuilder(
            builder: (context, setStateSB) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '$tempCredits Cr',
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Slider(
                    value: tempCredits,
                    min: 0.5,
                    max: 6.0,
                    divisions: 11,
                    onChanged: (val) => setStateSB(() => tempCredits = val),
                  ),
                ],
              );
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(widget.isEnglish ? 'Cancel' : '取消'),
            ),
            TextButton(
              onPressed: () {
                setState(() => _credits = tempCredits);
                Navigator.pop(context);
              },
              child: Text(widget.isEnglish ? 'Confirm' : '确定'),
            ),
          ],
        );
      },
    );
  }

  void _showWeeksDialog() {
    showDialog(
      context: context,
      builder: (context) {
        int tempStart = _startWeek;
        int tempEnd = _endWeek;
        return AlertDialog(
          title: Text(widget.isEnglish ? 'Select Weeks' : '选择周数范围'),
          content: StatefulBuilder(
            builder: (context, setStateSB) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '第 $tempStart - $tempEnd 周',
                    style: const TextStyle(fontSize: 16),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Text(widget.isEnglish ? 'Start: ' : '起始: '),
                      Expanded(
                        child: Slider(
                          value: tempStart.toDouble(),
                          min: 1,
                          max: 20,
                          divisions: 19,
                          onChanged: (val) {
                            setStateSB(() {
                              tempStart = val.toInt();
                              if (tempStart > tempEnd) tempEnd = tempStart;
                            });
                          },
                        ),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      Text(widget.isEnglish ? 'End:   ' : '结束: '),
                      Expanded(
                        child: Slider(
                          value: tempEnd.toDouble(),
                          min: 1,
                          max: 20,
                          divisions: 19,
                          onChanged: (val) {
                            setStateSB(() {
                              tempEnd = val.toInt();
                              if (tempEnd < tempStart) tempStart = tempEnd;
                            });
                          },
                        ),
                      ),
                    ],
                  ),
                ],
              );
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(widget.isEnglish ? 'Cancel' : '取消'),
            ),
            TextButton(
              onPressed: () {
                setState(() {
                  _startWeek = tempStart;
                  _endWeek = tempEnd;
                });
                Navigator.pop(context);
              },
              child: Text(widget.isEnglish ? 'Confirm' : '确定'),
            ),
          ],
        );
      },
    );
  }

  void _showTimeWeekdayDialog() {
    showDialog(
      context: context,
      builder: (context) {
        int tempWeekday = _weekday;
        String tempStart = _startTime;
        String tempEnd = _endTime;
        return AlertDialog(
          title: Text(widget.isEnglish ? 'Weekday & Time' : '星期与时间'),
          content: StatefulBuilder(
            builder: (context, setStateSB) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButton<int>(
                    value: tempWeekday,
                    isExpanded: true,
                    items: List.generate(7, (i) {
                      int day = i + 1;
                      const zh = ['', '周一', '周二', '周三', '周四', '周五', '周六', '周日'];
                      const en = [
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
                        value: day,
                        child: Text(widget.isEnglish ? en[day] : zh[day]),
                      );
                    }),
                    onChanged: (val) =>
                        setStateSB(() => tempWeekday = val ?? 1),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          decoration: InputDecoration(
                            labelText: widget.isEnglish ? 'Start Time' : '开始时间',
                          ),
                          controller: TextEditingController(text: tempStart),
                          onChanged: (val) => tempStart = val,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          decoration: InputDecoration(
                            labelText: widget.isEnglish ? 'End Time' : '结束时间',
                          ),
                          controller: TextEditingController(text: tempEnd),
                          onChanged: (val) => tempEnd = val,
                        ),
                      ),
                    ],
                  ),
                ],
              );
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(widget.isEnglish ? 'Cancel' : '取消'),
            ),
            TextButton(
              onPressed: () {
                setState(() {
                  _weekday = tempWeekday;
                  _startTime = tempStart;
                  _endTime = tempEnd;
                });
                Navigator.pop(context);
              },
              child: Text(widget.isEnglish ? 'Confirm' : '确定'),
            ),
          ],
        );
      },
    );
  }

  void _showColorPicker() {
    showModalBottomSheet(
      context: context,
      builder: (context) {
        return Container(
          padding: const EdgeInsets.all(20),
          height: 200,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.isEnglish ? 'Select Color Theme' : '选择课程主题色',
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: _colors.map((hex) {
                  Color color = _parseColor(hex);
                  return GestureDetector(
                    onTap: () {
                      setState(() => _selectedColor = hex);
                      Navigator.pop(context);
                    },
                    child: CircleAvatar(
                      backgroundColor: color,
                      radius: 24,
                      child: _selectedColor == hex
                          ? const Icon(Icons.check, color: Colors.white)
                          : null,
                    ),
                  );
                }).toList(),
              ),
            ],
          ),
        );
      },
    );
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
      id: DateTime.now().millisecondsSinceEpoch.toString(),
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
          ? '11A-120 St Lucia'
          : _locationController.text.trim(),
      teacher: _teacherController.text.trim().isEmpty
          ? 'Professor'
          : _teacherController.text.trim(),
      remark: _remarkController.text.trim(),
      enableReminder: true,
      reminderMinutes: 15,
      reminderCount: 1,
    );

    addCourse(course: newCourse);
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    const zh = ['', '周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    const en = ['', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final dayLabel = widget.isEnglish ? en[_weekday] : zh[_weekday];

    Color cardColor = _parseColor(_selectedColor);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isEnglish ? 'Add Course' : '添加课程'),
        actions: [
          TextButton(
            onPressed: _saveCourse,
            child: Text(
              widget.isEnglish ? 'Save' : '保存',
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: Colors.blueAccent,
              ),
            ),
          ),
        ],
      ),
      body: ListView(
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
            color: Colors.grey.shade100,
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
                      color: cardColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                  onTap: _showColorPicker,
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.star, color: Colors.orange),
                  title: Text(widget.isEnglish ? 'Credits' : '学分'),
                  trailing: Text(
                    '$_credits Cr',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  onTap: _showCreditsDialog,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Card(
            elevation: 0,
            color: Colors.grey.shade100,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.date_range, color: Colors.green),
                  title: Text(widget.isEnglish ? 'Weeks' : '周数'),
                  trailing: Text(
                    '${widget.isEnglish ? 'Weeks ' : '第'} $_startWeek - $_endWeek ${widget.isEnglish ? '' : '周'} >',
                  ),
                  onTap: _showWeeksDialog,
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.access_time, color: Colors.purple),
                  title: Text(widget.isEnglish ? 'Time & Weekday' : '节数与星期'),
                  trailing: Text('$dayLabel ($_startTime - $_endTime) >'),
                  onTap: _showTimeWeekdayDialog,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Card(
            elevation: 0,
            color: Colors.grey.shade100,
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
                      hintText: widget.isEnglish
                          ? 'Location (e.g. 11A-120 St Lucia)'
                          : '教室 (例如: 11A-120 St Lucia)',
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
                      hintText: widget.isEnglish ? 'Teacher' : '老师',
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
    );
  }
}

class ProfilePage extends StatelessWidget {
  final bool isEnglish;
  final ValueChanged<ThemeMode> onThemeChanged;
  final ValueChanged<bool> onLanguageChanged;
  final ThemeMode currentThemeMode;

  const ProfilePage({
    super.key,
    required this.isEnglish,
    required this.onThemeChanged,
    required this.onLanguageChanged,
    required this.currentThemeMode,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(isEnglish ? 'Profile & Settings' : '我的与设置')),
      body: ListView(
        children: [
          const SizedBox(height: 20),
          const CircleAvatar(
            radius: 40,
            backgroundColor: Colors.blueAccent,
            child: Icon(Icons.school, size: 40, color: Colors.white),
          ),
          const SizedBox(height: 12),
          Center(
            child: Text(
              isEnglish ? 'Timetable User' : '课表用户',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(height: 30),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.language),
            title: Text(isEnglish ? 'Language / 语言' : '语言 / Language'),
            trailing: DropdownButton<bool>(
              value: isEnglish,
              items: const [
                DropdownMenuItem(value: false, child: Text('简体中文')),
                DropdownMenuItem(value: true, child: Text('English')),
              ],
              onChanged: (val) {
                if (val != null) onLanguageChanged(val);
              },
            ),
          ),
          ListTile(
            leading: const Icon(Icons.brightness_6),
            title: Text(isEnglish ? 'ThemeMode / 主题模式' : '主题模式 / ThemeMode'),
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
                if (val != null) onThemeChanged(val);
              },
            ),
          ),
          const Divider(),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:timetable_app/src/rust/api/simple.dart';
import 'package:timetable_app/src/rust/frb_generated.dart';

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

  void _toggleTheme(ThemeMode mode) {
    setState(() {
      _themeMode = mode;
    });
  }

  void _toggleLanguage(bool isEnglish) {
    setState(() {
      _isEnglish = isEnglish;
    });
  }

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
        onTap: (index) {
          setState(() {
            _currentIndex = index;
          });
        },
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
                    ? 'No courses, click "+" on top to add'
                    : '暂无课程，请点击右上角 "+" 添加',
                style: const TextStyle(color: Colors.grey),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: _courses.length,
              itemBuilder: (context, index) {
                final course = _courses[index];
                return Card(
                  elevation: 2,
                  margin: const EdgeInsets.symmetric(vertical: 6),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: Colors.blue.shade100,
                      child: Text(
                        '周${course.weekday}',
                        style: const TextStyle(
                          color: Colors.blueAccent,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    title: Text(
                      course.name,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                    subtitle: Text(
                      widget.isEnglish
                          ? 'Time: ${course.startTime} - ${course.endTime}\nLocation: ${course.location} | Teacher: ${course.teacher}'
                          : '时间: ${course.startTime} - ${course.endTime}\n地点: ${course.location} | 老师: ${course.teacher}',
                    ),
                    isThreeLine: true,
                    trailing: Text('${course.credits} Cr'),
                  ),
                );
              },
            ),
    );
  }
}

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

  int _weekday = 1;
  double _credits = 3.0;
  final int _startWeek = 1;
  final int _endWeek = 16;
  final String _startTime = "08:00";
  final String _endTime = "09:40";

  void _saveCourse() {
    if (_nameController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            widget.isEnglish ? 'Please enter course name' : '请输入课程名称',
          ),
        ),
      );
      return;
    }

    // 注意这里传参名称已对应桥接后的驼峰命名
    final newCourse = Course(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: _nameController.text.trim(),
      color: "#3F51B5",
      credits: _credits,
      startWeek: _startWeek,
      endWeek: _endWeek,
      weekday: _weekday,
      totalSections: 2,
      hasBreak: true,
      startTime: _startTime,
      endTime: _endTime,
      location: _locationController.text.trim().isEmpty
          ? '教室'
          : _locationController.text.trim(),
      teacher: _teacherController.text.trim().isEmpty
          ? '老师'
          : _teacherController.text.trim(),
      remark: '',
      enableReminder: true,
      reminderMinutes: 15,
      reminderCount: 1,
    );

    addCourse(course: newCourse);
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isEnglish ? 'Add Course' : '手动添加课程'),
        actions: [
          IconButton(icon: const Icon(Icons.check), onPressed: _saveCourse),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _nameController,
            decoration: InputDecoration(
              labelText: widget.isEnglish ? 'Course Name' : '课程名称',
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _locationController,
                  decoration: InputDecoration(
                    labelText: widget.isEnglish
                        ? 'Location (e.g. A302)'
                        : '教室地址 (如 A302)',
                    border: const OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _teacherController,
                  decoration: InputDecoration(
                    labelText: widget.isEnglish ? 'Teacher' : '任课老师',
                    border: const OutlineInputBorder(),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<int>(
            value: _weekday,
            decoration: InputDecoration(
              labelText: widget.isEnglish ? 'Weekday' : '星期几',
              border: const OutlineInputBorder(),
            ),
            items: List.generate(7, (index) {
              int day = index + 1;
              String label = widget.isEnglish ? 'Monday' : '星期一';
              if (day == 2) label = widget.isEnglish ? 'Tuesday' : '星期二';
              if (day == 3) label = widget.isEnglish ? 'Wednesday' : '星期三';
              if (day == 4) label = widget.isEnglish ? 'Thursday' : '星期四';
              if (day == 5) label = widget.isEnglish ? 'Friday' : '星期五';
              if (day == 6) label = widget.isEnglish ? 'Saturday' : '星期六';
              if (day == 7) label = widget.isEnglish ? 'Sunday' : '星期日';
              return DropdownMenuItem(value: day, child: Text(label));
            }),
            onChanged: (val) => setState(() => _weekday = val ?? 1),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Text(widget.isEnglish ? 'Credits: ' : '学分数量: '),
              Expanded(
                child: Slider(
                  value: _credits,
                  min: 0.5,
                  max: 6.0,
                  divisions: 11,
                  label: _credits.toString(),
                  onChanged: (val) => setState(() => _credits = val),
                ),
              ),
              Text(_credits.toString()),
            ],
          ),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              minimumSize: const Size.fromHeight(50),
            ),
            onPressed: _saveCourse,
            icon: const Icon(Icons.save),
            label: Text(widget.isEnglish ? 'Save Course' : '保存课程'),
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
            title: Text(isEnglish ? 'Theme Mode / 主题模式' : '主题模式 / Theme Mode'),
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

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

/// 主界面：包含底部 3 个板块（日程、课表、我的）
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
  int _currentIndex = 1; // 默认停留在“课表”页（第2个）

  @override
  Widget build(BuildContext context) {
    // 根据语言定义底栏文字
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

/// 1. 日程页面（预留）
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

/// 2. 核心课表页面（纯净风，参考高颜值截图）
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
    // 自动从 Rust 加载第 1 周课程
    final list = getCoursesForWeek(week: 1);
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
        centerTitle: false,
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: widget.isEnglish ? 'Add Course' : '添加课程',
            onPressed: () {
              // 之后这里跳到添加课程表单
            },
          ),
        ],
      ),
      body: _courses.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    widget.isEnglish
                        ? 'No timetable, import or add one'
                        : '无课表，可手动添加或一键导入',
                    style: const TextStyle(color: Colors.grey),
                  ),
                  const SizedBox(height: 12),
                  ElevatedButton(
                    onPressed: _loadData,
                    child: Text(widget.isEnglish ? 'Load Data' : '加载测试课程'),
                  ),
                ],
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: _courses.length,
              itemBuilder: (context, index) {
                final course = _courses[index];
                // 根据语言动态显示课程名
                final courseName = widget.isEnglish && course.name == '软件工程课'
                    ? 'Software Engineering'
                    : course.name;
                final teacherName = widget.isEnglish && course.teacher == '老师'
                    ? 'Professor'
                    : course.teacher;

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
                        '${course.weekday}',
                        style: const TextStyle(color: Colors.blueAccent),
                      ),
                    ),
                    title: Text(
                      courseName,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                    subtitle: Text(
                      widget.isEnglish
                          ? 'Time: ${course.startTime} - ${course.endTime}\nLocation: ${course.location} | Teacher: $teacherName'
                          : '时间: ${course.startTime} - ${course.endTime}\n地点: ${course.location} | 老师: $teacherName',
                    ),
                    isThreeLine: true,
                    trailing: Text(
                      widget.isEnglish
                          ? '${course.credits} Cr'
                          : '${course.credits}学分',
                    ),
                  ),
                );
              },
            ),
    );
  }
}

/// 3. “我的”板块：把设置、语言、主题全部收纳在这里（符合高级 APP 规范）
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
          // 语言切换选项
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
          // 主题模式选项
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

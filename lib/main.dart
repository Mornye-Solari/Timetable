import 'package:flutter/material.dart';
import 'package:timetable_app/src/rust/api/simple.dart';
import 'package:timetable_app/src/rust/frb_generated.dart';

Future<void> main() async {
  await RustLib.init();
  runApp(const TimetableApp());
}

class TimetableApp extends StatelessWidget {
  const TimetableApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Timetable',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const TimetablePage(),
    );
  }
}

class TimetablePage extends StatefulWidget {
  const TimetablePage({super.key});

  @override
  State<TimetablePage> createState() => _TimetablePageState();
}

class _TimetablePageState extends State<TimetablePage> {
  int _currentWeek = 1;
  static const List<String> _weekDays = [
    '周一',
    '周二',
    '周三',
    '周四',
    '周五',
    '周六',
    '周日',
  ];
  static const int _maxPeriods = 8;

  @override
  Widget build(BuildContext context) {
    // 同步零开销调用 Rust 核心层获取当前周课程
    final courses = getCoursesForWeek(week: _currentWeek);

    return Scaffold(
      appBar: AppBar(
        title: Text('第 $_currentWeek 周课程表 (Rust Core)'),
        actions: [
          IconButton(
            icon: const Icon(Icons.chevron_left),
            tooltip: '上一周',
            onPressed: _currentWeek > 1
                ? () => setState(() => _currentWeek--)
                : null,
          ),
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8.0),
              child: Text(
                'Week $_currentWeek',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            tooltip: '下一周',
            onPressed: _currentWeek < 20
                ? () => setState(() => _currentWeek++)
                : null,
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: Column(
        children: [
          _buildHeaderRow(),
          const Divider(height: 1),
          Expanded(child: SingleChildScrollView(child: _buildGrid(courses))),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.bolt),
        label: const Text('测试冲突检测'),
        onPressed: () {
          // 调用 Rust 位运算冲突检测：测试在周一第 1-2 节插入课程
          final conflictMsg = checkConflict(
            dayOfWeek: 1,
            startPeriod: 1,
            endPeriod: 2,
            weekMask: 1 << _currentWeek,
          );
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(conflictMsg ?? '当前时段无冲突，可以排课！'),
              behavior: SnackBarBehavior.floating,
            ),
          );
        },
      ),
    );
  }

  Widget _buildHeaderRow() {
    return Container(
      color: Colors.indigo.withValues(alpha: 0.06),
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          const SizedBox(
            width: 56,
            child: Center(
              child: Text('节次', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ),
          ..._weekDays.map(
            (day) => Expanded(
              child: Center(
                child: Text(
                  day,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGrid(List<CourseSlot> courses) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 左侧节次栏
        SizedBox(
          width: 56,
          child: Column(
            children: List.generate(
              _maxPeriods,
              (index) => Container(
                height: 68,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(color: Colors.grey.shade300, width: 0.5),
                  ),
                ),
                child: Text(
                  '${index + 1}',
                  style: TextStyle(color: Colors.grey.shade700),
                ),
              ),
            ),
          ),
        ),
        // 7 天课程列
        ...List.generate(7, (dayIndex) {
          final day = dayIndex + 1;
          final dayCourses = courses.where((c) => c.dayOfWeek == day).toList();
          return Expanded(
            child: Container(
              height: _maxPeriods * 68.0,
              decoration: BoxDecoration(
                border: Border(
                  left: BorderSide(color: Colors.grey.shade300, width: 0.5),
                ),
              ),
              child: Stack(
                children: [
                  // 背景横线
                  Column(
                    children: List.generate(
                      _maxPeriods,
                      (_) => Container(
                        height: 68,
                        decoration: BoxDecoration(
                          border: Border(
                            bottom: BorderSide(
                              color: Colors.grey.shade200,
                              width: 0.5,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  // 渲染课程卡片
                  ...dayCourses.map((course) {
                    final top = (course.startPeriod - 1) * 68.0;
                    final height =
                        (course.endPeriod - course.startPeriod + 1) * 68.0;
                    return Positioned(
                      top: top + 2,
                      left: 2,
                      right: 2,
                      height: height - 4,
                      child: Card(
                        margin: EdgeInsets.zero,
                        color: Colors.indigo.shade50,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(6),
                          side: BorderSide(color: Colors.indigo.shade200),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(6.0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                course.name,
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                  color: Colors.indigo.shade900,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const Spacer(),
                              Text(
                                '@${course.location}',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.indigo.shade700,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              Text(
                                course.teacher,
                                style: TextStyle(
                                  fontSize: 10,
                                  color: Colors.grey.shade600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  }),
                ],
              ),
            ),
          );
        }),
      ],
    );
  }
}

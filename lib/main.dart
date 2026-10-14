import 'package:flutter/material.dart';
import 'package:timetable_app/src/rust/api/simple.dart';
import 'package:timetable_app/src/rust/frb_generated.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Timetable App',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String _greetingMessage = "点击下方按钮测试 Rust 后端";

  void _callRustBackend() {
    // 注意：因为是同步函数，这里直接调用，不需要 await！
    final result = greet(name: "我的课表");
    setState(() {
      _greetingMessage = result;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('我的智能课表'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text(
                '欢迎使用 Rust + Flutter 架构！',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 20),
              Text(
                _greetingMessage,
                style: const TextStyle(fontSize: 16, color: Colors.blueAccent),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 40),
              ElevatedButton.icon(
                onPressed: _callRustBackend,
                icon: const Icon(Icons.bolt),
                label: const Text('呼叫 Rust 后端'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

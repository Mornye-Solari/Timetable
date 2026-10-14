use serde::{Deserialize, Serialize};

/// 课程详细数据结构（对应你的构思第16条）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Course {
    pub id: String,            // 课程唯一标识
    pub name: String,          // 1. 课程名称
    pub color: String,         // 2. 背景颜色
    pub credits: f32,          // 3. 学分数量
    pub start_week: u32,       // 4. 开始周数
    pub end_week: u32,         // 5. 结束周数
    pub weekday: u8,           // 6. 星期几（1-7）
    pub total_sections: u32,   // 7. 总节数
    pub has_break: bool,       // 8. 是否存在课间
    pub start_time: String,    // 9. 开始时间
    pub end_time: String,      // 10. 结束时间
    pub location: String,      // 11. 教室地址
    pub teacher: String,       // 12. 任课老师
    pub remark: String,        // 13. 备注
    pub enable_reminder: bool, // 14. 是否开启提醒
    pub reminder_minutes: u32, // 15. 提前多少分钟
    pub reminder_count: u32,   // 16. 提醒几次
}

/// 测试函数：前后端连通性测试
#[flutter_rust_bridge::frb(sync)]
pub fn greet(name: String) -> String {
    format!("你好，{}！Rust 后端运行正常！", name)
}

/// 初始化应用
#[flutter_rust_bridge::frb(sync)]
pub fn init_app() {
    // 留空或初始化逻辑
}

/// 检查课程时间冲突
#[flutter_rust_bridge::frb(sync)]
pub fn check_conflict() -> bool {
    false
}

/// 获取某一週的课程列表
#[flutter_rust_bridge::frb(sync)]
pub fn get_courses_for_week(week: u32) -> Vec<Course> {
    Vec::new()
}

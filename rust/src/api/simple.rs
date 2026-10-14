use serde::{Deserialize, Serialize};
use std::sync::Mutex;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Course {
    pub id: String,
    pub name: String,           // 课程名称
    pub color: String,          // 背景颜色
    pub credits: f32,           // 学分
    pub start_week: u32,        // 开始周
    pub end_week: u32,          // 结束周
    pub weekday: u8,            // 星期几
    pub total_sections: u32,    // 总节数
    pub has_break: bool,        // 课间
    pub start_time: String,     // 开始时间
    pub end_time: String,       // 结束时间
    pub location: String,       // 教室
    pub teacher: String,        // 老师
    pub remark: String,         // 备注
    pub enable_reminder: bool,  // 提醒开关
    pub reminder_minutes: u32,  // 提前分钟
    pub reminder_count: u32,    // 提醒次数
}

lazy_static::lazy_static! {
    static ref COURSE_LIST: Mutex<Vec<Course>> = Mutex::new(vec![
        Course {
            id: "1".to_string(),
            name: "软件工程课".to_string(),
            color: "#4CAF50".to_string(),
            credits: 3.0,
            start_week: 1,
            end_week: 16,
            weekday: 4,
            total_sections: 2,
            has_break: true,
            start_time: "08:00".to_string(),
            end_time: "09:40".to_string(),
            location: "教学楼 A302".to_string(),
            teacher: "教授".to_string(),
            remark: "记得带电脑".to_string(),
            enable_reminder: true,
            reminder_minutes: 15,
            reminder_count: 1,
        }
    ]);
}

#[flutter_rust_bridge::frb(sync)]
pub fn greet(name: String) -> String {
    format!("你好，{}！Rust 后端运行正常！", name)
}

#[flutter_rust_bridge::frb(sync)]
pub fn init_app() {}

#[flutter_rust_bridge::frb(sync)]
pub fn check_conflict() -> bool {
    false
}

#[flutter_rust_bridge::frb(sync)]
pub fn get_courses_for_week(_week: u32) -> Vec<Course> {
    let list = COURSE_LIST.lock().unwrap();
    list.clone()
}

#[flutter_rust_bridge::frb(sync)]
pub fn add_course(course: Course) {
    let mut list = COURSE_LIST.lock().unwrap();
    list.push(course);
}
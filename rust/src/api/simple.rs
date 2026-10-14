use flutter_rust_bridge::frb;

/// 单节课程紧凑内存结构
#[derive(Clone, Debug)]
pub struct CourseSlot {
    pub id: u32,
    pub name: String,
    pub location: String,
    pub teacher: String,
    pub day_of_week: u8,  // 1 = 周一 ... 7 = 周日
    pub start_period: u8, // 开始节次 (如第 1 节)
    pub end_period: u8,   // 结束节次 (如第 2 节)
    pub week_mask: u32,   // 位掩码：第 n 周有课则第 n 位为 1
}

/// 检查指定周次是否有课（极速位运算）
#[inline(always)]
fn is_active_in_week(mask: u32, week: u8) -> bool {
    if week == 0 || week > 30 {
        return false;
    }
    (mask & (1u32 << week)) != 0
}

/// 获取指定周次的全部有效课程（按星期和节次排序）
#[frb(sync)]
pub fn get_courses_for_week(week: u8) -> Vec<CourseSlot> {
    let all_courses = get_mock_courses();
    let mut result: Vec<CourseSlot> = all_courses
        .into_iter()
        .filter(|c| is_active_in_week(c.week_mask, week))
        .collect();

    result.sort_unstable_by_key(|c| (c.day_of_week, c.start_period));
    result
}

/// 检测新课程与现有课程是否存在时间冲突（位掩码 + 区间重叠判定）
#[frb(sync)]
pub fn check_conflict(
    day_of_week: u8,
    start_period: u8,
    end_period: u8,
    week_mask: u32,
) -> Option<String> {
    for c in get_mock_courses() {
        // 1. 星期相同  2. 周次位掩码有交集  3. 节次区间重叠
        if c.day_of_week == day_of_week
            && (c.week_mask & week_mask) != 0
            && start_period <= c.end_period
            && end_period >= c.start_period
        {
            return Some(format!(
                "与《{}》(周{} 第{}-{}节) 存在时间冲突",
                c.name, c.day_of_week, c.start_period, c.end_period
            ));
        }
    }
    None
}

/// 初始示例课程数据（第 1~16 周掩码为 0x1FFFE）
fn get_mock_courses() -> Vec<CourseSlot> {
    let weeks_1_to_16: u32 = 0x1FFFE; // 1~16周全周
    let odd_weeks: u32 = 0x15554; // 1,3,5...15单周
    let even_weeks: u32 = 0x0AAAA; // 2,4,6...16双周

    vec![
        CourseSlot {
            id: 1,
            name: "软件工程".to_string(),
            location: "教学楼 A302".to_string(),
            teacher: "陈教授".to_string(),
            day_of_week: 1,
            start_period: 1,
            end_period: 2,
            week_mask: weeks_1_to_16,
        },
        CourseSlot {
            id: 2,
            name: "操作系统内核".to_string(),
            location: "实验楼 B105".to_string(),
            teacher: "林老师".to_string(),
            day_of_week: 2,
            start_period: 3,
            end_period: 4,
            week_mask: weeks_1_to_16,
        },
        CourseSlot {
            id: 3,
            name: "编译原理 (单周)".to_string(),
            location: "教学楼 C201".to_string(),
            teacher: "王教授".to_string(),
            day_of_week: 3,
            start_period: 1,
            end_period: 2,
            week_mask: odd_weeks,
        },
        CourseSlot {
            id: 4,
            name: "高性能计算实验 (双周)".to_string(),
            location: "机房 D404".to_string(),
            teacher: "张老师".to_string(),
            day_of_week: 3,
            start_period: 1,
            end_period: 2,
            week_mask: even_weeks,
        },
        CourseSlot {
            id: 5,
            name: "计算机网络".to_string(),
            location: "教学楼 A108".to_string(),
            teacher: "赵老师".to_string(),
            day_of_week: 5,
            start_period: 5,
            end_period: 6,
            week_mask: weeks_1_to_16,
        },
    ]
}

#[frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}

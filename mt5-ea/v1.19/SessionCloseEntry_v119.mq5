//+------------------------------------------------------------------+
//|                                           SessionCloseEntry.mq5  |
//|  收盘前 N 分钟检查一次价格条件，满足则按设定开仓（多品种可配置）    |
//|                                                                  |
//|  定时条件开仓工具：只执行明确配置的任务，错过不补单、不重复执行。    |
//|  v1.19 为开发版本：须先经 MetaEditor 编译并在模拟账户验证后再考虑实盘。|
//+------------------------------------------------------------------+
//  v1.10：新增“指定日期仅执行一次”（默认），保留“按星期重复”；新增任务状态显示。
//         事件记录名称格式与 v1.00 相同，旧记录继续有效，升级后不会重复执行旧任务。
//  v1.11：运行连续性检测（休眠/长时间停顿后不执行检查）；平仓结果按返回码+持仓核对；
//         防重复记录写入后读回核对，写入失败禁止下单并在本实例内封锁该任务。
//  v1.12：每组处理前取最新时间；发开仓单前复核时间窗口与运行连续性；连续性检测覆盖回调内部阻塞；
//         平仓结果需持仓列表+成交历史+连接状态共同确认，不再把“查询不到”当作已平仓。
//  v1.13：在“发送中”记录建立之后、紧邻 Buy/Sell 调用之前，再做一次连续性检查与时间/连接/就绪复核。
//  v1.14：新增可选模式——开仓条件“到点直接执行”、手数“品种最小手数”、止盈止损“距开仓价的价格差”。
//         所有新参数默认值等于旧行为，旧 .set 加载后效果不变。
//  v1.15：价格差模式成交后调整止盈止损时，结果不明确则进入有期限的只读核对，确认实际保护后才下结论。
//  v1.16：修正交易时段判断——当日时段只算当日部分，另查前一日跨午夜延续到当日的尾段
//         （v1.15 在服务器 00:00–00:14:59 把 12:00–次日00:15 的尾段误判为“不在交易时段”）。
//  v1.17：仅显示层——图表面板由 Comment() 改为 OBJ_LABEL 文本对象（字号 12），每行内容与 v1.16 相同；
//         EA 卸载时删除面板对象。交易逻辑、时段判断、参数、全局变量行为不变。
//  v1.18：仅显示层——每组任务改为两行显示（字段不增不减），超过 1500 像素的行在“ | ”处兜底折行。
//  v1.19：安全性与功能升级（新参数默认值均等于旧行为，旧 .set 加载后效果不变；事件编号、全局变量、日志文件名不变）——
//         ① 开仓条件新增“价格区间”（最低价 ≤ 价格 ≤ 最高价）；② 止盈止损新增“账户货币金额”模式（OrderCalcProfit 换算并反算验证）；
//         ③ 每组可设最大允许点差；④ “发送中”记录建立后、下单调用前，按最新报价做统一安全复核
//         （价格条件、点差、止盈止损、交易时段/模式、手数、权限、已有持仓/挂单），任何一项不通过即不下单；
//         ⑤ 日志与面板显示检查报价、允许区间、点差、止盈止损与未执行原因。
//         时间/时区计算、就绪与连续性机制、防重复记录、下单后核对与平仓逻辑未改动。
#property version     "1.19"
#property description "收盘前N分钟检查一次价格条件，满足则按设定方向/手数以市价开仓，并带固定止盈止损。"
#property description "默认“仅记录信号”，不会下单。详细说明见随附的中文说明文档。"

#include <Trade\Trade.mqh>

//==================== 常量 ====================
#define SLOT_COUNT      5      // 支持的品种组数
#define ARM_SECONDS     120    // 检查时刻前多少秒内EA必须已在正常运行（用于识别“刚启动/刚恢复”）
#define VERIFY_SECONDS  60     // 下单后核对订单/成交的最长时间（秒）
#define CLOSE_VERIFY_SECONDS 30 // 发出平仓请求后核对仓位是否关闭的最长时间（秒）
#define STOPS_VERIFY_SECONDS 30 // 调整止盈止损后（结果不明确时）只读核对实际保护的最长时间（秒）
#define MIN_CONTINUOUS_SECONDS 30 // 刚启动或刚从中断恢复后，需连续运行满这么多秒才允许进入“就绪”
#define GV_PREFIX       "SCE_" // 事件记录（终端全局变量）名称前缀

// 事件状态（写入终端全局变量，终端重启后仍保留，用于防止重复下单）
#define ST_NOT_MET      1      // 已检查：条件不满足
#define ST_SIGNAL       2      // 已检查：条件满足，仅记录信号
#define ST_SKIPPED      3      // 已检查：因某项检查未通过而跳过
#define ST_MISSED       4      // 错过检查时刻（启动/重启/断线恢复），不补单
#define ST_SENDING      5      // 正在发送订单（若停留在此状态，说明发送过程中被中断）
#define ST_SENT_OK      6      // 已成交
#define ST_SEND_FAIL    7      // 下单被拒绝/失败
#define ST_UNCERTAIN    8      // 下单结果不明确（正在核对，不重试）
#define ST_MANUAL       9      // 核对期内未确认成交，需人工核对（v1.10 新增）
#define ST_STOPS_ISSUE  10     // 已成交，止盈止损异常，且仓位未确认关闭（需人工处理）
#define ST_CLOSED_NO_STOPS 11  // 已成交，止盈止损补设失败，已确认平仓（v1.11 新增）
#define ST_CLOSE_PENDING 12    // 已发出平仓请求，结果待确认（v1.11 新增）
#define ST_RECORD_FAIL  13     // 防重复记录写入失败（只存在于本实例内存，不会写入全局变量）
#define ST_CLOSED_OTHER 14     // 仓位已确认关闭，但不能确认由本EA的平仓请求关闭（v1.12 新增）
#define ST_STOPS_INEXACT 15    // 已成交，已确认实际有双边保护，但距离未按实际成交价精确调整（v1.15 起需核对确认后才使用）
#define ST_STOPS_PENDING 16    // 保护状态待核对：调整结果不明确，正在只读核对或核对超时（v1.15 新增）

//==================== 选项枚举（参数窗口里显示为下拉菜单） ====================
enum ENUM_RUN_MODE
  {
   RUN_SIGNAL_ONLY = 0,   // 仅记录信号（不下单）
   RUN_TRADE       = 1    // 允许交易（会实际下单）
  };

enum ENUM_SERVER_TZ_MODE
  {
   SERVER_TZ_AUTO   = 0,  // 自动：由电脑时钟和时区推算
   SERVER_TZ_MANUAL = 1   // 手动：使用下方填写的偏移
  };

enum ENUM_TZ
  {
   TZ_BEIJING   = 0,      // 北京时间 UTC+8（无夏令时）
   TZ_NEW_YORK  = 1,      // 纽约时间（美国夏令时规则）
   TZ_CHICAGO   = 2,      // 芝加哥时间（美国夏令时规则）
   TZ_LONDON    = 3,      // 伦敦时间（欧洲夏令时规则）
   TZ_FRANKFURT = 4,      // 法兰克福/巴黎时间（欧洲夏令时规则）
   TZ_TOKYO     = 5,      // 东京时间 UTC+9（无夏令时）
   TZ_UTC       = 6,      // UTC 协调世界时
   TZ_SERVER    = 7,      // 券商服务器时间
   TZ_CUSTOM    = 8       // 自定义固定UTC偏移（无夏令时）
  };

enum ENUM_EXEC_MODE
  {
   EXEC_ONCE   = 0,       // 指定日期仅执行一次
   EXEC_WEEKLY = 1        // 按星期重复
  };

enum ENUM_COND
  {
   COND_NOT_SET = 0,      // 未设置（不会交易）
   COND_GTE     = 1,      // 价格 ≥ 阈值（不低于）
   COND_LTE     = 2,      // 价格 ≤ 阈值（不高于）
   COND_ALWAYS  = 3,      // 到点直接执行（不判断价格，其他检查照常）
   COND_RANGE   = 4       // 价格区间：最低价 ≤ 价格 ≤ 最高价（v1.19）
  };

enum ENUM_LOT_MODE
  {
   LOT_FIXED = 0,         // 指定手数
   LOT_MIN   = 1          // 使用该品种允许的最小手数（检查时从账户品种规格读取）
  };

enum ENUM_STOPS_MODE
  {
   STOPS_PRICE    = 0,    // 固定止盈止损价格
   STOPS_DISTANCE = 1,    // 距开仓价的价格差（如 20.0 = 相差 20 个价格单位）
   STOPS_MONEY    = 2     // 账户货币金额（如 盈利60 / 亏损20，按品种规格和手数换算，v1.19）
  };

enum ENUM_DIR
  {
   DIR_NOT_SET = 0,       // 未设置（不会交易）
   DIR_BUY     = 1,       // 买入（用 Ask 判断条件）
   DIR_SELL    = 2        // 卖出（用 Bid 判断条件）
  };

//==================== 全局参数 ====================
input group "========== 全局设置 =========="
input ENUM_RUN_MODE       InpRunMode              = RUN_SIGNAL_ONLY; // 运行模式
input bool                InpDemoOnly             = true;            // 只允许在模拟账户下单
input long                InpMagic                = 26102201;        // Magic Number（本EA专用编号）
input int                 InpGraceSeconds         = 60;              // 容错窗口（秒）
input int                 InpMaxTimerGapSec       = 10;              // 定时器允许的最大停顿（秒），超过视为运行中断
input int                 InpMaxQuoteAgeSec       = 30;              // 报价超过多少秒未更新视为过期
input int                 InpDeviationPoints      = 20;              // 允许滑点（点，部分账户类型不生效）
input bool                InpCloseIfNoStops       = true;            // 成交后止盈止损补设失败时平掉该笔仓位
input ENUM_SERVER_TZ_MODE InpServerTzMode         = SERVER_TZ_AUTO;  // 券商服务器时区识别方式
input double              InpServerUtcOffsetHours = 0.0;             // 手动：服务器时间=UTC+几小时（仅手动模式）
input bool                InpWriteLogFile         = true;            // 同时写入日志文件（MQL5\Files）

//==================== 品种1 ====================
input group "========== 品种1 =========="
input bool      S1_Enabled      = false;        // 启用
input ENUM_EXEC_MODE S1_ExecMode = EXEC_ONCE;   // 执行方式
input string    S1_Symbol       = "";           // 品种名称（与MT5“市场报价”完全一致）
input string    S1_CloseDate    = "";           // 一次性：目标收盘日期 YYYY.MM.DD（按下方时区）
input string    S1_CloseTime    = "";           // 目标收盘时间 HH:MM（例 16:00）
input ENUM_TZ   S1_TimeZone     = TZ_BEIJING;   // 收盘时间所属时区
input double    S1_CustomOffset = 0.0;          // 自定义UTC偏移（小时，仅选“自定义”时使用）
input int       S1_LeadMinutes  = 5;            // 提前检查分钟数
input bool      S1_Mon          = false;        // 重复模式：周一（一次性模式忽略星期）
input bool      S1_Tue          = false;        // 重复模式：周二
input bool      S1_Wed          = false;        // 重复模式：周三
input bool      S1_Thu          = false;        // 重复模式：周四
input bool      S1_Fri          = false;        // 重复模式：周五
input bool      S1_Sat          = false;        // 重复模式：周六
input bool      S1_Sun          = false;        // 重复模式：周日
input ENUM_COND S1_Condition    = COND_NOT_SET; // 开仓条件（≥/≤阈值、价格区间，或到点直接执行）
input double    S1_Threshold    = 0.0;          // 触发阈值（仅 ≥ / ≤ 条件使用）
input ENUM_DIR  S1_Direction    = DIR_NOT_SET;  // 开仓方向
input ENUM_LOT_MODE S1_LotMode  = LOT_FIXED;    // 手数模式
input double    S1_Lots         = 0.0;          // 手数（仅“指定手数”模式）
input ENUM_STOPS_MODE S1_StopsMode = STOPS_PRICE; // 止盈止损模式
input double    S1_TakeProfit   = 0.0;          // 止盈价格（仅“固定价格”模式，必填）
input double    S1_StopLoss     = 0.0;          // 止损价格（仅“固定价格”模式，必填）
input double    S1_TPDistance   = 0.0;          // 止盈距离（仅“价格差”模式，价格差，如 20.0）
input double    S1_SLDistance   = 0.0;          // 止损距离（仅“价格差”模式，价格差，如 20.0）
input double    S1_RangeLow     = 0.0;          // 区间最低价（仅“价格区间”条件，v1.19）
input double    S1_RangeHigh    = 0.0;          // 区间最高价（仅“价格区间”条件，v1.19）
input double    S1_TPMoney      = 0.0;          // 止盈金额（仅“账户货币金额”模式，如 60 = 盈利60，v1.19）
input double    S1_SLMoney      = 0.0;          // 止损金额（仅“账户货币金额”模式，如 20 = 亏损20，v1.19）
input double    S1_MaxSpread    = 0.0;          // 最大允许点差（价格单位，Ask−Bid；0=不限制，v1.19）

//==================== 品种2 ====================
input group "========== 品种2 =========="
input bool      S2_Enabled      = false;        // 启用
input ENUM_EXEC_MODE S2_ExecMode = EXEC_ONCE;   // 执行方式
input string    S2_Symbol       = "";           // 品种名称（与MT5“市场报价”完全一致）
input string    S2_CloseDate    = "";           // 一次性：目标收盘日期 YYYY.MM.DD（按下方时区）
input string    S2_CloseTime    = "";           // 目标收盘时间 HH:MM（例 16:00）
input ENUM_TZ   S2_TimeZone     = TZ_BEIJING;   // 收盘时间所属时区
input double    S2_CustomOffset = 0.0;          // 自定义UTC偏移（小时，仅选“自定义”时使用）
input int       S2_LeadMinutes  = 5;            // 提前检查分钟数
input bool      S2_Mon          = false;        // 重复模式：周一（一次性模式忽略星期）
input bool      S2_Tue          = false;        // 重复模式：周二
input bool      S2_Wed          = false;        // 重复模式：周三
input bool      S2_Thu          = false;        // 重复模式：周四
input bool      S2_Fri          = false;        // 重复模式：周五
input bool      S2_Sat          = false;        // 重复模式：周六
input bool      S2_Sun          = false;        // 重复模式：周日
input ENUM_COND S2_Condition    = COND_NOT_SET; // 开仓条件（≥/≤阈值、价格区间，或到点直接执行）
input double    S2_Threshold    = 0.0;          // 触发阈值（仅 ≥ / ≤ 条件使用）
input ENUM_DIR  S2_Direction    = DIR_NOT_SET;  // 开仓方向
input ENUM_LOT_MODE S2_LotMode  = LOT_FIXED;    // 手数模式
input double    S2_Lots         = 0.0;          // 手数（仅“指定手数”模式）
input ENUM_STOPS_MODE S2_StopsMode = STOPS_PRICE; // 止盈止损模式
input double    S2_TakeProfit   = 0.0;          // 止盈价格（仅“固定价格”模式，必填）
input double    S2_StopLoss     = 0.0;          // 止损价格（仅“固定价格”模式，必填）
input double    S2_TPDistance   = 0.0;          // 止盈距离（仅“价格差”模式，价格差，如 20.0）
input double    S2_SLDistance   = 0.0;          // 止损距离（仅“价格差”模式，价格差，如 20.0）
input double    S2_RangeLow     = 0.0;          // 区间最低价（仅“价格区间”条件，v1.19）
input double    S2_RangeHigh    = 0.0;          // 区间最高价（仅“价格区间”条件，v1.19）
input double    S2_TPMoney      = 0.0;          // 止盈金额（仅“账户货币金额”模式，如 60 = 盈利60，v1.19）
input double    S2_SLMoney      = 0.0;          // 止损金额（仅“账户货币金额”模式，如 20 = 亏损20，v1.19）
input double    S2_MaxSpread    = 0.0;          // 最大允许点差（价格单位，Ask−Bid；0=不限制，v1.19）

//==================== 品种3 ====================
input group "========== 品种3 =========="
input bool      S3_Enabled      = false;        // 启用
input ENUM_EXEC_MODE S3_ExecMode = EXEC_ONCE;   // 执行方式
input string    S3_Symbol       = "";           // 品种名称（与MT5“市场报价”完全一致）
input string    S3_CloseDate    = "";           // 一次性：目标收盘日期 YYYY.MM.DD（按下方时区）
input string    S3_CloseTime    = "";           // 目标收盘时间 HH:MM（例 16:00）
input ENUM_TZ   S3_TimeZone     = TZ_BEIJING;   // 收盘时间所属时区
input double    S3_CustomOffset = 0.0;          // 自定义UTC偏移（小时，仅选“自定义”时使用）
input int       S3_LeadMinutes  = 5;            // 提前检查分钟数
input bool      S3_Mon          = false;        // 重复模式：周一（一次性模式忽略星期）
input bool      S3_Tue          = false;        // 重复模式：周二
input bool      S3_Wed          = false;        // 重复模式：周三
input bool      S3_Thu          = false;        // 重复模式：周四
input bool      S3_Fri          = false;        // 重复模式：周五
input bool      S3_Sat          = false;        // 重复模式：周六
input bool      S3_Sun          = false;        // 重复模式：周日
input ENUM_COND S3_Condition    = COND_NOT_SET; // 开仓条件（≥/≤阈值、价格区间，或到点直接执行）
input double    S3_Threshold    = 0.0;          // 触发阈值（仅 ≥ / ≤ 条件使用）
input ENUM_DIR  S3_Direction    = DIR_NOT_SET;  // 开仓方向
input ENUM_LOT_MODE S3_LotMode  = LOT_FIXED;    // 手数模式
input double    S3_Lots         = 0.0;          // 手数（仅“指定手数”模式）
input ENUM_STOPS_MODE S3_StopsMode = STOPS_PRICE; // 止盈止损模式
input double    S3_TakeProfit   = 0.0;          // 止盈价格（仅“固定价格”模式，必填）
input double    S3_StopLoss     = 0.0;          // 止损价格（仅“固定价格”模式，必填）
input double    S3_TPDistance   = 0.0;          // 止盈距离（仅“价格差”模式，价格差，如 20.0）
input double    S3_SLDistance   = 0.0;          // 止损距离（仅“价格差”模式，价格差，如 20.0）
input double    S3_RangeLow     = 0.0;          // 区间最低价（仅“价格区间”条件，v1.19）
input double    S3_RangeHigh    = 0.0;          // 区间最高价（仅“价格区间”条件，v1.19）
input double    S3_TPMoney      = 0.0;          // 止盈金额（仅“账户货币金额”模式，如 60 = 盈利60，v1.19）
input double    S3_SLMoney      = 0.0;          // 止损金额（仅“账户货币金额”模式，如 20 = 亏损20，v1.19）
input double    S3_MaxSpread    = 0.0;          // 最大允许点差（价格单位，Ask−Bid；0=不限制，v1.19）

//==================== 品种4 ====================
input group "========== 品种4 =========="
input bool      S4_Enabled      = false;        // 启用
input ENUM_EXEC_MODE S4_ExecMode = EXEC_ONCE;   // 执行方式
input string    S4_Symbol       = "";           // 品种名称（与MT5“市场报价”完全一致）
input string    S4_CloseDate    = "";           // 一次性：目标收盘日期 YYYY.MM.DD（按下方时区）
input string    S4_CloseTime    = "";           // 目标收盘时间 HH:MM（例 16:00）
input ENUM_TZ   S4_TimeZone     = TZ_BEIJING;   // 收盘时间所属时区
input double    S4_CustomOffset = 0.0;          // 自定义UTC偏移（小时，仅选“自定义”时使用）
input int       S4_LeadMinutes  = 5;            // 提前检查分钟数
input bool      S4_Mon          = false;        // 重复模式：周一（一次性模式忽略星期）
input bool      S4_Tue          = false;        // 重复模式：周二
input bool      S4_Wed          = false;        // 重复模式：周三
input bool      S4_Thu          = false;        // 重复模式：周四
input bool      S4_Fri          = false;        // 重复模式：周五
input bool      S4_Sat          = false;        // 重复模式：周六
input bool      S4_Sun          = false;        // 重复模式：周日
input ENUM_COND S4_Condition    = COND_NOT_SET; // 开仓条件（≥/≤阈值、价格区间，或到点直接执行）
input double    S4_Threshold    = 0.0;          // 触发阈值（仅 ≥ / ≤ 条件使用）
input ENUM_DIR  S4_Direction    = DIR_NOT_SET;  // 开仓方向
input ENUM_LOT_MODE S4_LotMode  = LOT_FIXED;    // 手数模式
input double    S4_Lots         = 0.0;          // 手数（仅“指定手数”模式）
input ENUM_STOPS_MODE S4_StopsMode = STOPS_PRICE; // 止盈止损模式
input double    S4_TakeProfit   = 0.0;          // 止盈价格（仅“固定价格”模式，必填）
input double    S4_StopLoss     = 0.0;          // 止损价格（仅“固定价格”模式，必填）
input double    S4_TPDistance   = 0.0;          // 止盈距离（仅“价格差”模式，价格差，如 20.0）
input double    S4_SLDistance   = 0.0;          // 止损距离（仅“价格差”模式，价格差，如 20.0）
input double    S4_RangeLow     = 0.0;          // 区间最低价（仅“价格区间”条件，v1.19）
input double    S4_RangeHigh    = 0.0;          // 区间最高价（仅“价格区间”条件，v1.19）
input double    S4_TPMoney      = 0.0;          // 止盈金额（仅“账户货币金额”模式，如 60 = 盈利60，v1.19）
input double    S4_SLMoney      = 0.0;          // 止损金额（仅“账户货币金额”模式，如 20 = 亏损20，v1.19）
input double    S4_MaxSpread    = 0.0;          // 最大允许点差（价格单位，Ask−Bid；0=不限制，v1.19）

//==================== 品种5 ====================
input group "========== 品种5 =========="
input bool      S5_Enabled      = false;        // 启用
input ENUM_EXEC_MODE S5_ExecMode = EXEC_ONCE;   // 执行方式
input string    S5_Symbol       = "";           // 品种名称（与MT5“市场报价”完全一致）
input string    S5_CloseDate    = "";           // 一次性：目标收盘日期 YYYY.MM.DD（按下方时区）
input string    S5_CloseTime    = "";           // 目标收盘时间 HH:MM（例 16:00）
input ENUM_TZ   S5_TimeZone     = TZ_BEIJING;   // 收盘时间所属时区
input double    S5_CustomOffset = 0.0;          // 自定义UTC偏移（小时，仅选“自定义”时使用）
input int       S5_LeadMinutes  = 5;            // 提前检查分钟数
input bool      S5_Mon          = false;        // 重复模式：周一（一次性模式忽略星期）
input bool      S5_Tue          = false;        // 重复模式：周二
input bool      S5_Wed          = false;        // 重复模式：周三
input bool      S5_Thu          = false;        // 重复模式：周四
input bool      S5_Fri          = false;        // 重复模式：周五
input bool      S5_Sat          = false;        // 重复模式：周六
input bool      S5_Sun          = false;        // 重复模式：周日
input ENUM_COND S5_Condition    = COND_NOT_SET; // 开仓条件（≥/≤阈值、价格区间，或到点直接执行）
input double    S5_Threshold    = 0.0;          // 触发阈值（仅 ≥ / ≤ 条件使用）
input ENUM_DIR  S5_Direction    = DIR_NOT_SET;  // 开仓方向
input ENUM_LOT_MODE S5_LotMode  = LOT_FIXED;    // 手数模式
input double    S5_Lots         = 0.0;          // 手数（仅“指定手数”模式）
input ENUM_STOPS_MODE S5_StopsMode = STOPS_PRICE; // 止盈止损模式
input double    S5_TakeProfit   = 0.0;          // 止盈价格（仅“固定价格”模式，必填）
input double    S5_StopLoss     = 0.0;          // 止损价格（仅“固定价格”模式，必填）
input double    S5_TPDistance   = 0.0;          // 止盈距离（仅“价格差”模式，价格差，如 20.0）
input double    S5_SLDistance   = 0.0;          // 止损距离（仅“价格差”模式，价格差，如 20.0）
input double    S5_RangeLow     = 0.0;          // 区间最低价（仅“价格区间”条件，v1.19）
input double    S5_RangeHigh    = 0.0;          // 区间最高价（仅“价格区间”条件，v1.19）
input double    S5_TPMoney      = 0.0;          // 止盈金额（仅“账户货币金额”模式，如 60 = 盈利60，v1.19）
input double    S5_SLMoney      = 0.0;          // 止损金额（仅“账户货币金额”模式，如 20 = 亏损20，v1.19）
input double    S5_MaxSpread    = 0.0;          // 最大允许点差（价格单位，Ask−Bid；0=不限制，v1.19）

//==================== 内部数据结构 ====================
struct SlotConfig
  {
   bool              enabled;
   ENUM_EXEC_MODE    execMode;
   string            symbol;
   string            closeDateText;    // 一次性模式：目标收盘日期原文
   datetime          closeDate;        // 一次性模式：目标收盘日期（当地 00:00）
   string            closeTimeText;
   int               closeMinutes;     // 收盘时间：当地午夜后的分钟数
   ENUM_TZ           tz;
   double            customOffsetH;
   int               leadMinutes;
   bool              weekdays[7];      // 0=周日 ... 6=周六（按目标时区的当地日期）
   ENUM_COND         cond;
   double            threshold;
   ENUM_DIR          dir;
   double            lots;
   double            tp;
   double            sl;
   ENUM_LOT_MODE     lotMode;
   ENUM_STOPS_MODE   stopsMode;
   double            tpDist;           // 价格差模式：止盈距离
   double            slDist;           // 价格差模式：止损距离
   double            effLots;          // 本次检查实际使用的手数（检查时确定）
   double            rangeLow;         // v1.19 价格区间：最低价
   double            rangeHigh;        // v1.19 价格区间：最高价
   double            tpMoney;          // v1.19 金额模式：止盈金额（账户货币）
   double            slMoney;          // v1.19 金额模式：止损金额（账户货币）
   double            maxSpread;        // v1.19 最大允许点差（价格单位；0=不限制）
   double            effTpDist;        // v1.19 金额模式：本次换算出的止盈距离（检查/发单时确定）
   double            effSlDist;        // v1.19 金额模式：本次换算出的止损距离
   bool              valid;
   string            invalidReason;
  };

struct SlotState
  {
   string            armedKey;         // 检查时刻前已“就绪”的事件（EA在检查前正常运行且已连接）
   string            retryReason;      // 窗口内暂未取得有效报价的原因
   string            retryLoggedKey;
   string            lastResult;       // 图表上显示的上次结果
   string            lastInfo;         // v1.19 本实例内最近一次结果的摘要（检查报价/点差/原因），仅用于面板显示
   string            lastInfoKey;      // v1.19 lastInfo 对应的事件
   string            scheduleKey;      // 已记录过的“下一次检查”事件
   bool              verifyActive;     // 是否正在核对下单结果
   datetime          verifyUntilUtc;
   datetime          verifyFromServer;
   string            verifyKey;
   bool              stopsVerifyActive; // 是否正在只读核对止盈止损（v1.15）
   ulong             stopsTicket;
   long              stopsPosId;
   double            stopsWantSl;
   double            stopsWantTp;
   datetime          stopsUntilUtc;
   string            stopsKey;
   string            stopsNote;         // 调整经过说明（用于最终日志）
   string            stopsLastWhy;
   bool              closeVerifyActive; // 是否正在核对平仓结果
   ulong             closeTicket;
   long              closePosId;        // 持仓标识 POSITION_IDENTIFIER
   ulong             closeOrderTicket;  // 本EA平仓请求返回的订单号（0=未返回）
   string            closeLastWhy;      // 上一次“无法确认”的原因（避免重复写日志）
   double            closeOrigVol;
   datetime          closeUntilUtc;
   string            closeKey;
  };

struct EventInfo
  {
   datetime          localDate;        // 目标时区当地日期（00:00）
   datetime          closeUtc;         // 收盘时刻（UTC）
   datetime          checkUtc;         // 检查时刻（UTC）
   string            key;              // 事件唯一编号（全局变量名）
  };

//==================== 全局变量 ====================
CTrade     g_trade;
SlotConfig g_cfg[SLOT_COUNT];
SlotState  g_st[SLOT_COUNT];
int        g_serverOffsetSec = 0;
bool       g_offsetOk        = false;
bool       g_offsetInit      = false;
string     g_lockName        = "";
string     g_hbName          = "";
double     g_instanceId      = 0.0;
bool       g_lockHeld        = false;
bool       g_lastConnected   = true;
string     g_logFile         = "";
datetime   g_lastCkptUtc     = 0;     // 上一个连续性检查点的 UTC 时间
ulong      g_lastCkptMs      = 0;     // 上一个连续性检查点的单调计时（毫秒）
string     g_lastGapInfo     = "";
string     g_lockError       = "";
datetime   g_runStartUtc     = 0;     // 本段“连续运行”的开始时刻（启动或上次中断恢复时）    // 最近一次运行中断的说明（图表显示）
string     g_blockedKeys[];           // 记录写入失败、本实例内不再处理的任务
int        g_blockedStates[];
string     g_chartNote       = "";    // v1.19 图表品种与任务品种不一致时的提示（仅显示）
string     g_wd[7]           = {"周日","周一","周二","周三","周四","周五","周六"};

//+------------------------------------------------------------------+
//| 时间工具                                                          |
//+------------------------------------------------------------------+
datetime MakeDate(const int y,const int m,const int d)
  {
   MqlDateTime t;
   ZeroMemory(t);
   t.year=y;
   t.mon=m;
   t.day=d;
   return StructToTime(t);
  }

int DayOfWeek(const datetime t)
  {
   MqlDateTime s;
   TimeToStruct(t,s);
   return s.day_of_week;
  }

int YearOf(const datetime t)
  {
   MqlDateTime s;
   TimeToStruct(t,s);
   return s.year;
  }

int DaysInMonth(const int y,const int m)
  {
   datetime a=MakeDate(y,m,1);
   datetime b=(m==12) ? MakeDate(y+1,1,1) : MakeDate(y,m+1,1);
   return (int)(((long)b-(long)a)/86400);
  }

// 某年某月第 n 个周日（n 从 1 开始）
datetime NthSunday(const int y,const int m,const int n)
  {
   datetime first=MakeDate(y,m,1);
   int dow=DayOfWeek(first);
   int firstSun=1+(7-dow)%7;
   return MakeDate(y,m,firstSun+7*(n-1));
  }

// 某年某月最后一个周日
datetime LastSunday(const int y,const int m)
  {
   datetime last=MakeDate(y,m,DaysInMonth(y,m));
   return (datetime)((long)last-(long)DayOfWeek(last)*86400);
  }

// 美国夏令时（2007年起的规则）：3月第2个周日 当地02:00 开始，11月第1个周日 当地02:00 结束
bool UsDstAtUtc(const datetime utc,const int stdOffsetSec)
  {
   int y=YearOf(utc);
   long startUtc=(long)NthSunday(y,3,2)+2*3600-stdOffsetSec;
   long endUtc  =(long)NthSunday(y,11,1)+2*3600-(stdOffsetSec+3600);
   return ((long)utc>=startUtc && (long)utc<endUtc);
  }

// 欧洲夏令时：3月最后一个周日 01:00 UTC 开始，10月最后一个周日 01:00 UTC 结束
bool EuDstAtUtc(const datetime utc)
  {
   int y=YearOf(utc);
   long s=(long)LastSunday(y,3)+3600;
   long e=(long)LastSunday(y,10)+3600;
   return ((long)utc>=s && (long)utc<e);
  }

// 指定时区在某个UTC时刻相对UTC的偏移（秒）
int ZoneOffsetAtUtc(const ENUM_TZ tz,const double customH,const datetime utc)
  {
   switch(tz)
     {
      case TZ_BEIJING:   return 8*3600;
      case TZ_TOKYO:     return 9*3600;
      case TZ_UTC:       return 0;
      case TZ_NEW_YORK:  return UsDstAtUtc(utc,-5*3600) ? -4*3600 : -5*3600;
      case TZ_CHICAGO:   return UsDstAtUtc(utc,-6*3600) ? -5*3600 : -6*3600;
      case TZ_LONDON:    return EuDstAtUtc(utc) ? 3600 : 0;
      case TZ_FRANKFURT: return EuDstAtUtc(utc) ? 7200 : 3600;
      case TZ_SERVER:    return g_serverOffsetSec;
      case TZ_CUSTOM:    return (int)MathRound(customH*3600.0);
      default:           return 0;
     }
  }

// 当地时间 -> UTC（处理夏令时切换；切换当天“不存在/重复”的当地时间取较早的UTC）
datetime LocalToUtc(const ENUM_TZ tz,const double customH,const datetime local)
  {
   int off1=ZoneOffsetAtUtc(tz,customH,local);
   datetime utc1=(datetime)((long)local-off1);
   int off2=ZoneOffsetAtUtc(tz,customH,utc1);
   if(off2==off1)
      return utc1;
   datetime utc2=(datetime)((long)local-off2);
   int off3=ZoneOffsetAtUtc(tz,customH,utc2);
   if(off3==off2)
      return utc2;
   return ((long)utc1<(long)utc2) ? utc1 : utc2;
  }

string OffsetText(const int sec)
  {
   string sign=(sec<0) ? "-" : "+";
   int a=(sec<0) ? -sec : sec;
   int h=a/3600;
   int m=(a%3600)/60;
   if(m==0)
      return sign+IntegerToString(h);
   return sign+IntegerToString(h)+":"+StringFormat("%02d",m);
  }

string TzName(const int i)
  {
   switch(g_cfg[i].tz)
     {
      case TZ_BEIJING:   return "北京时间";
      case TZ_NEW_YORK:  return "纽约时间";
      case TZ_CHICAGO:   return "芝加哥时间";
      case TZ_LONDON:    return "伦敦时间";
      case TZ_FRANKFURT: return "法兰克福时间";
      case TZ_TOKYO:     return "东京时间";
      case TZ_UTC:       return "UTC";
      case TZ_SERVER:    return "服务器时间";
      case TZ_CUSTOM:    return "自定义 UTC"+OffsetText((int)MathRound(g_cfg[i].customOffsetH*3600.0));
      default:           return "?";
     }
  }

string FmtDT(const datetime t)
  {
   return TimeToString(t,TIME_DATE|TIME_SECONDS)+" "+g_wd[DayOfWeek(t)];
  }

string FmtDTm(const datetime t)
  {
   return TimeToString(t,TIME_DATE|TIME_MINUTES)+" "+g_wd[DayOfWeek(t)];
  }

string DateKey(const datetime d)
  {
   MqlDateTime s;
   TimeToStruct(d,s);
   return StringFormat("%04d%02d%02d",s.year,s.mon,s.day);
  }

//+------------------------------------------------------------------+
//| 当前UTC时间与服务器偏移                                            |
//+------------------------------------------------------------------+
datetime NowUtc()
  {
   if(InpServerTzMode==SERVER_TZ_MANUAL)
      return (datetime)((long)TimeTradeServer()-g_serverOffsetSec);
   return TimeGMT();
  }

void UpdateServerOffset()
  {
   int  prev=g_serverOffsetSec;
   bool prevOk=g_offsetOk;
   if(InpServerTzMode==SERVER_TZ_MANUAL)
     {
      g_serverOffsetSec=(int)MathRound(InpServerUtcOffsetHours*3600.0);
      g_offsetOk=true;
     }
   else
     {
      long diff=(long)TimeTradeServer()-(long)TimeGMT();
      int rounded=(int)(MathRound((double)diff/900.0)*900.0);   // 取整到15分钟
      g_offsetOk=(rounded>=-12*3600 && rounded<=14*3600);
      if(g_offsetOk)
         g_serverOffsetSec=rounded;
     }
   if(!g_offsetInit || prev!=g_serverOffsetSec || prevOk!=g_offsetOk)
     {
      g_offsetInit=true;
      if(g_offsetOk)
         Log("服务器时间偏移：UTC"+OffsetText(g_serverOffsetSec)
             +((InpServerTzMode==SERVER_TZ_AUTO) ? "（自动推算，依赖电脑时钟和Windows时区设置正确）" : "（手动设置）"));
      else
         Log("警告：自动推算的服务器时间偏移异常，暂停所有下单检查。请核对电脑时间/时区，或改用手动偏移。");
     }
  }

//+------------------------------------------------------------------+
//| 通用工具                                                          |
//+------------------------------------------------------------------+
void Log(const string msg)
  {
   datetime utc=NowUtc();
   string line="北京 "+FmtDT((datetime)((long)utc+8*3600))+" | 服务器 "+FmtDT(TimeTradeServer())+" | "+msg;
   Print(line);
   if(!InpWriteLogFile || g_logFile=="")
      return;
   int h=FileOpen(g_logFile,FILE_READ|FILE_WRITE|FILE_TXT|FILE_SHARE_READ|FILE_SHARE_WRITE);
   if(h==INVALID_HANDLE)
      return;
   if(FileSize(h)==0)
      FileWriteString(h,ShortToString(0xFEFF));   // UTF-16 文件头，方便记事本识别
   FileSeek(h,0,SEEK_END);
   FileWriteString(h,line+"\r\n");
   FileClose(h);
  }

string P(const string sym,const double v)
  {
   int d=(int)SymbolInfoInteger(sym,SYMBOL_DIGITS);
   return DoubleToString(v,d);
  }

string NumStr(const double v)
  {
   string s=DoubleToString(v,8);
   int n=StringLen(s);
   while(n>0 && StringGetCharacter(s,n-1)=='0')
      n--;
   if(n>0 && StringGetCharacter(s,n-1)=='.')
      n--;
   return StringSubstr(s,0,n);
  }

double TickSize(const string sym)
  {
   double ts=SymbolInfoDouble(sym,SYMBOL_TRADE_TICK_SIZE);
   if(ts<=0.0)
      ts=SymbolInfoDouble(sym,SYMBOL_POINT);
   return ts;
  }

string SlotTag(const int i)
  {
   return "品种"+IntegerToString(i+1)+" ["+g_cfg[i].symbol+"]";
  }

string DirText(const ENUM_DIR d)
  {
   if(d==DIR_BUY)
      return "买入";
   if(d==DIR_SELL)
      return "卖出";
   return "未设置";
  }

string CondText(const ENUM_COND c)
  {
   if(c==COND_GTE)
      return "≥";
   if(c==COND_LTE)
      return "≤";
   if(c==COND_ALWAYS)
      return "到点直接执行";
   if(c==COND_RANGE)
      return "价格区间";
   return "?";
  }

string CondDesc(const int i)
  {
   if(g_cfg[i].cond==COND_ALWAYS)
      return "到点直接执行（不判断价格）";
   if(g_cfg[i].cond==COND_RANGE)
      return P(g_cfg[i].symbol,g_cfg[i].rangeLow)+" ≤ "+QuoteName(g_cfg[i].dir)+" ≤ "+P(g_cfg[i].symbol,g_cfg[i].rangeHigh);
   return QuoteName(g_cfg[i].dir)+" "+CondText(g_cfg[i].cond)+" "+P(g_cfg[i].symbol,g_cfg[i].threshold);
  }

string LotsDesc(const int i)
  {
   if(g_cfg[i].lotMode==LOT_MIN)
      return "品种最小手数";
   return NumStr(g_cfg[i].lots)+" 手";
  }

string StopsDesc(const int i)
  {
   string sym=g_cfg[i].symbol;
   if(g_cfg[i].stopsMode==STOPS_MONEY)
      return "止盈 盈利"+NumStr(g_cfg[i].tpMoney)+" 止损 亏损"+NumStr(g_cfg[i].slMoney)
             +"（账户货币金额 "+AccountInfoString(ACCOUNT_CURRENCY)+"）";
   if(g_cfg[i].stopsMode==STOPS_DISTANCE)
     {
      string sg=(g_cfg[i].dir==DIR_SELL) ? "-" : "+";
      string sl=(g_cfg[i].dir==DIR_SELL) ? "+" : "-";
      return "止盈 开仓价"+sg+NumStr(g_cfg[i].tpDist)+" 止损 开仓价"+sl+NumStr(g_cfg[i].slDist)+"（价格差）";
     }
   return "止盈 "+P(sym,g_cfg[i].tp)+" 止损 "+P(sym,g_cfg[i].sl);
  }

string QuoteName(const ENUM_DIR d)
  {
   return (d==DIR_BUY) ? "Ask" : "Bid";
  }

//---- v1.19 新增的小工具 ----
// 止盈止损是否按“距开仓价的距离”处理（价格差模式，或金额模式换算后）
bool StopsByDist(const int i)
  {
   return (g_cfg[i].stopsMode==STOPS_DISTANCE || g_cfg[i].stopsMode==STOPS_MONEY);
  }

double EffTpDist(const int i)
  {
   return (g_cfg[i].stopsMode==STOPS_MONEY) ? g_cfg[i].effTpDist : g_cfg[i].tpDist;
  }

double EffSlDist(const int i)
  {
   return (g_cfg[i].stopsMode==STOPS_MONEY) ? g_cfg[i].effSlDist : g_cfg[i].slDist;
  }

// 价格条件是否满足（price：买入为 Ask，卖出为 Bid）。区间条件须上下限同时满足。
bool PriceCondMet(const int i,const double price)
  {
   double eps=SymbolInfoDouble(g_cfg[i].symbol,SYMBOL_POINT)*0.001;
   switch(g_cfg[i].cond)
     {
      case COND_ALWAYS: return true;
      case COND_GTE:    return (price>=g_cfg[i].threshold-eps);
      case COND_LTE:    return (price<=g_cfg[i].threshold+eps);
      case COND_RANGE:  return (price>=g_cfg[i].rangeLow-eps && price<=g_cfg[i].rangeHigh+eps);
      default:          return false;
     }
  }

// 点差说明：当前点差（价格单位与点数）及上限
string SpreadDesc(const int i,const MqlTick &tk)
  {
   string sym=g_cfg[i].symbol;
   double point=SymbolInfoDouble(sym,SYMBOL_POINT);
   double sp=tk.ask-tk.bid;
   string s="点差="+P(sym,sp);
   if(point>0.0)
      s+="（"+IntegerToString((long)MathRound(sp/point))+" 点）";
   s+=(g_cfg[i].maxSpread>0.0) ? "，上限 "+NumStr(g_cfg[i].maxSpread) : "，未设上限";
   return s;
  }

// 点差检查：返回空字符串表示通过（未设上限时始终通过）
string SpreadCheck(const int i,const MqlTick &tk)
  {
   if(g_cfg[i].maxSpread<=0.0)
      return "";
   string sym=g_cfg[i].symbol;
   double sp=tk.ask-tk.bid;
   double eps=SymbolInfoDouble(sym,SYMBOL_POINT)*0.001;
   if(sp>g_cfg[i].maxSpread+eps)
      return "点差超限：当前点差 "+P(sym,sp)+"（Bid="+P(sym,tk.bid)+" Ask="+P(sym,tk.ask)+"）大于最大允许点差 "
             +NumStr(g_cfg[i].maxSpread);
   return "";
  }

// 用 MT5 盈亏计算功能核算：以 open 开仓、在 close 平仓时，账户货币盈亏是多少
bool CalcProfit(const string sym,const bool isBuy,const double lots,const double openPrice,const double closePrice,double &profit)
  {
   profit=0.0;
   ResetLastError();
   return OrderCalcProfit(isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL,sym,lots,openPrice,closePrice,profit);
  }

// 金额模式：把账户货币金额换算成距开仓价的价格距离。
// 做法：用 OrderCalcProfit 分别测出“有利方向/不利方向每个最小价格变动”的盈亏（按本次手数和方向，含券商的货币换算），
// 止盈取最接近目标金额的价位，止损向下取整（理论亏损不超过目标金额）；再用 OrderCalcProfit 反算两个价位的实际金额做验证。
// 返回空字符串表示成功；否则返回原因（调用方不下单）。
string MoneyToDistances(const int i,const double lots,const double ref,double &tpDist,double &slDist,string &note)
  {
   tpDist=0.0;
   slDist=0.0;
   note="";
   string sym=g_cfg[i].symbol;
   bool   isBuy=(g_cfg[i].dir==DIR_BUY);
   string ccy=AccountInfoString(ACCOUNT_CURRENCY);
   double ts=TickSize(sym);
   if(ts<=0.0)
      return "无法读取该品种的最小价格变动";
   if(lots<=0.0 || ref<=0.0)
      return "金额换算所需的手数或参考价无效";
   long n=1000;                                   // 用 1000 个最小变动做探测，降低金额取整带来的误差
   long room=(long)MathFloor(ref/ts)-1;           // 向下探测不能低于 0
   if(room<n)
      n=room;
   if(n<1)
      return "参考价过低，无法做金额换算";
   double span=(double)n*ts;
   double up=ref+span,dn=ref-span;
   double win=0.0,loss=0.0;
   if(!CalcProfit(sym,isBuy,lots,ref,isBuy ? up : dn,win) || !CalcProfit(sym,isBuy,lots,ref,isBuy ? dn : up,loss))
      return "OrderCalcProfit 计算失败（错误码 "+IntegerToString(GetLastError())+"），无法把金额换算为价格";
   double perWin=win/(double)n;
   double perLoss=-loss/(double)n;
   if(!(perWin>0.0) || !(perLoss>0.0))
      return "OrderCalcProfit 返回的每个最小价格变动盈亏无效（有利 "+NumStr(perWin)+"，不利 "+NumStr(perLoss)+"），无法换算";
   double tpTicks=MathRound(g_cfg[i].tpMoney/perWin);
   double slTicks=MathFloor(g_cfg[i].slMoney/perLoss+1e-7);
   if(tpTicks<1.0)
      return "止盈金额 "+NumStr(g_cfg[i].tpMoney)+" "+ccy+" 小于一个最小价格变动对应的盈亏（约 "+DoubleToString(perWin,4)+"），无法设置";
   if(slTicks<1.0)
      return "止损金额 "+NumStr(g_cfg[i].slMoney)+" "+ccy+" 小于一个最小价格变动对应的盈亏（约 "+DoubleToString(perLoss,4)+"），无法设置";
   double td=tpTicks*ts,sd=slTicks*ts;
   double tpPrice=RoundToTick(sym,isBuy ? ref+td : ref-td);
   double slPrice=RoundToTick(sym,isBuy ? ref-sd : ref+sd);
   if(tpPrice<=0.0 || slPrice<=0.0)
      return "按金额换算出的止盈/止损价格无效";
   // 反算验证
   double vTp=0.0,vSl=0.0;
   if(!CalcProfit(sym,isBuy,lots,ref,tpPrice,vTp) || !CalcProfit(sym,isBuy,lots,ref,slPrice,vSl))
      return "OrderCalcProfit 反算验证失败（错误码 "+IntegerToString(GetLastError())+"）";
   double vLoss=-vSl;
   if(MathAbs(vTp-g_cfg[i].tpMoney)>perWin*0.5+0.011)
      return "金额换算验证未通过：止盈目标 "+NumStr(g_cfg[i].tpMoney)+"，按换算价位核算为 "+DoubleToString(vTp,2)+" "+ccy;
   if(vLoss>g_cfg[i].slMoney+0.011 || vLoss<g_cfg[i].slMoney-perLoss-0.011)
      return "金额换算验证未通过：止损目标 "+NumStr(g_cfg[i].slMoney)+"，按换算价位核算为 "+DoubleToString(vLoss,2)+" "+ccy;
   tpDist=td;
   slDist=sd;
   note="金额换算（OrderCalcProfit，"+NumStr(lots)+" 手 "+DirText(g_cfg[i].dir)+"，参考价 "+P(sym,ref)+"）："
        +"止盈 "+NumStr(g_cfg[i].tpMoney)+" "+ccy+" → 距离 "+NumStr(td)+"（核算 +"+DoubleToString(vTp,2)+"）；"
        +"止损 "+NumStr(g_cfg[i].slMoney)+" "+ccy+" → 距离 "+NumStr(sd)+"（核算 -"+DoubleToString(vLoss,2)+"）";
   return "";
  }

// 金额模式：按实际成交价和实际止盈止损价核算预计盈亏（仅用于日志）
string MoneyAudit(const int i,const bool isBuy,const double vol,const double openPrice,const double sl,const double tp)
  {
   if(g_cfg[i].stopsMode!=STOPS_MONEY)
      return "";
   string sym=g_cfg[i].symbol;
   double a=0.0,b=0.0;
   if(!CalcProfit(sym,isBuy,vol,openPrice,tp,a) || !CalcProfit(sym,isBuy,vol,openPrice,sl,b))
      return " | 按实际成交价核算金额失败（OrderCalcProfit 错误码 "+IntegerToString(GetLastError())+"）";
   return " | 按实际成交价 "+P(sym,openPrice)+" 核算（OrderCalcProfit）：触及止盈约 +"+DoubleToString(a,2)+"，触及止损约 "
          +DoubleToString(b,2)+" "+AccountInfoString(ACCOUNT_CURRENCY)
          +"（目标 +"+NumStr(g_cfg[i].tpMoney)+" / -"+NumStr(g_cfg[i].slMoney)
          +"；止损成交滑点、手续费、隔夜利息不在此数内）";
  }

// 从结果详情中取出以 prefix 开头的一段（到下一个“ | ”为止），取不到返回空
string DetailField(const string detail,const string prefix)
  {
   int p=StringFind(detail,prefix);
   if(p<0)
      return "";
   int q=StringFind(detail," | ",p);
   return (q<0) ? StringSubstr(detail,p) : StringSubstr(detail,p,q-p);
  }

string StateText(const int st)
  {
   switch(st)
     {
      case ST_NOT_MET:     return "条件不满足（已结束）";
      case ST_SIGNAL:      return "已记录信号（仅记录模式，未下单，已结束）";
      case ST_SKIPPED:     return "失败：下单前检查未通过（已结束）";
      case ST_MISSED:      return "已错过（已结束，不补单）";
      case ST_SENDING:     return "待人工核对：下单过程被中断";
      case ST_SENT_OK:     return "已成交";
      case ST_SEND_FAIL:   return "失败：下单被拒绝（已结束）";
      case ST_UNCERTAIN:   return "待人工核对：下单结果不明确";
      case ST_MANUAL:      return "待人工核对：核对期内未确认成交";
      case ST_STOPS_ISSUE: return "待人工核对：已成交，止盈止损异常，仓位未确认关闭";
      case ST_CLOSED_NO_STOPS: return "已成交后平仓：止盈止损补设失败，已确认由本EA平仓请求关闭";
      case ST_CLOSED_OTHER: return "仓位已确认关闭，但关闭来源不能确认是本EA的平仓请求（见日志）";
      case ST_CLOSE_PENDING: return "待人工核对：平仓结果未确认";
      case ST_RECORD_FAIL: return "未下单：防重复记录写入失败，需人工核对";
      case ST_STOPS_INEXACT: return "已成交；已确认有双边保护，但距离未按实际成交价精确调整（实际价格见日志）";
      case ST_STOPS_PENDING: return "待人工核对：保护状态待核对（无法确认实际止盈止损）";
      default:             return "未知状态 "+IntegerToString(st);
     }
  }

// 任务当前状态（供图表显示）
string EventStatusText(const int i,EventInfo &ev,const datetime nowUtc)
  {
   if(g_st[i].verifyActive && g_st[i].verifyKey==ev.key)
      return "处理中：正在核对订单/成交";
   if(g_st[i].closeVerifyActive && g_st[i].closeKey==ev.key)
      return "处理中：正在确认平仓结果";
   if(g_st[i].stopsVerifyActive && g_st[i].stopsKey==ev.key)
      return "处理中：正在只读核对实际止盈止损";
   int bi=BlockedIndex(ev.key);
   if(bi>=0)
      return StateText(g_blockedStates[bi])+"（记录未能写入全局变量，本实例已停止处理该任务）";
   if(GlobalVariableCheck(ev.key))
      return StateText((int)GlobalVariableGet(ev.key));
   long now=(long)nowUtc;
   long chk=(long)ev.checkUtc;
   if(now<chk)
      return "待执行（距检查还有 "+DurText(chk-now)+"）";
   if(now<=chk+InpGraceSeconds)
      return "处理中：检查时刻已到";
   return "已错过（即将记录）";
  }

string DurText(const long secs)
  {
   long s=(secs<0) ? 0 : secs;
   long d=s/86400;
   long h=(s%86400)/3600;
   long m=(s%3600)/60;
   if(d>0)
      return IntegerToString(d)+"天"+IntegerToString(h)+"小时"+IntegerToString(m)+"分";
   if(h>0)
      return IntegerToString(h)+"小时"+IntegerToString(m)+"分";
   if(m>0)
      return IntegerToString(m)+"分"+IntegerToString(s%60)+"秒";
   return IntegerToString(s)+"秒";
  }

// 解析 YYYY.MM.DD（也接受 - / 分隔）
bool ParseDate(const string text,datetime &d)
  {
   string t=text;
   StringReplace(t,"-",".");
   StringReplace(t,"/",".");
   StringReplace(t,"。",".");
   StringTrimLeft(t);
   StringTrimRight(t);
   string parts[];
   if(StringSplit(t,'.',parts)!=3)
      return false;
   for(int k=0;k<3;k++)
     {
      int len=StringLen(parts[k]);
      if(len<1 || len>((k==0) ? 4 : 2))
         return false;
      for(int c=0;c<len;c++)
        {
         ushort ch=StringGetCharacter(parts[k],c);
         if(ch<'0' || ch>'9')
            return false;
        }
     }
   if(StringLen(parts[0])!=4)
      return false;
   int y=(int)StringToInteger(parts[0]);
   int m=(int)StringToInteger(parts[1]);
   int dd=(int)StringToInteger(parts[2]);
   if(y<2000 || y>2100 || m<1 || m>12 || dd<1 || dd>DaysInMonth(y,m))
      return false;
   d=MakeDate(y,m,dd);
   return true;
  }

string WeekdaysText(const int i)
  {
   string s="";
   int order[7]={1,2,3,4,5,6,0};
   for(int k=0;k<7;k++)
      if(g_cfg[i].weekdays[order[k]])
         s+=(s=="" ? "" : " ")+g_wd[order[k]];
   return (s=="") ? "无" : s;
  }

bool ParseHHMM(const string text,int &minutes)
  {
   string t=text;
   StringReplace(t,"：",":");
   StringTrimLeft(t);
   StringTrimRight(t);
   string parts[];
   if(StringSplit(t,':',parts)!=2)
      return false;
   for(int k=0;k<2;k++)
     {
      int len=StringLen(parts[k]);
      if(len<1 || len>2)
         return false;
      for(int c=0;c<len;c++)
        {
         ushort ch=StringGetCharacter(parts[k],c);
         if(ch<'0' || ch>'9')
            return false;
        }
     }
   int h=(int)StringToInteger(parts[0]);
   int m=(int)StringToInteger(parts[1]);
   if(h<0 || h>23 || m<0 || m>59)
      return false;
   minutes=h*60+m;
   return true;
  }

ENUM_ORDER_TYPE_FILLING GetFilling(const string sym)
  {
   long fm=SymbolInfoInteger(sym,SYMBOL_FILLING_MODE);
   if((fm & SYMBOL_FILLING_FOK)==SYMBOL_FILLING_FOK)
      return ORDER_FILLING_FOK;
   if((fm & SYMBOL_FILLING_IOC)==SYMBOL_FILLING_IOC)
      return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
  }

bool IsNetting()
  {
   return (AccountInfoInteger(ACCOUNT_MARGIN_MODE)!=ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);
  }

//+------------------------------------------------------------------+
//| 交易时段                                                          |
//+------------------------------------------------------------------+
// 把一个原始时段（f/t 为所属星期当天 00:00 起的秒数）拆成两部分：
//   当日部分 [a,b)，以及延续到次日的尾段 [0,tail)（tail=0 表示不跨午夜）。区间均为开始包含、结束不包含。
// 跨午夜的两种表示都按此处理：结束值 > 86400（如 to=87300）；开始 > 结束（如 from=43200 to=900）。
// 全天 0–86400 按 [0,86400) 处理，不取模。起止相同（含义不明）、负值、开始 ≥ 86400 的时段返回 false，不放行。
bool SplitSession(const long f,const long t,long &a,long &b,long &tail)
  {
   a=0;
   b=0;
   tail=0;
   if(f<0 || t<0 || f>=86400 || f==t)
      return false;
   a=f;
   if(f<t)
     {
      b=(t<86400) ? t : 86400;
      tail=(t>86400) ? t-86400 : 0;
     }
   else
     {
      b=86400;
      tail=t;
     }
   if(tail>86400)
      tail=86400;   // 不支持跨越超过一整天的时段：尾段最多算到次日 24:00
   return true;
  }

// serverTime 是否处于该品种的交易时段；endSec 返回该时段结束时刻（按 serverTime 当天 00:00 起算的秒数，
// 大于等于 86400 表示次日）。先查当日时段（只算当日部分），再查前一日跨午夜延续到当日的尾段。
bool FindTradeSession(const string sym,const datetime serverTime,long &endSec)
  {
   MqlDateTime s;
   TimeToStruct(serverTime,s);
   long sec=s.hour*3600+s.min*60+s.sec;
   int  prevDow=(s.day_of_week+6)%7;
   datetime from,to;
   long a=0,b=0,tail=0;
   for(uint idx=0;idx<20;idx++)
     {
      if(!SymbolInfoSessionTrade(sym,(ENUM_DAY_OF_WEEK)s.day_of_week,idx,from,to))
         break;
      if(!SplitSession((long)from,(long)to,a,b,tail))
         continue;
      if(sec>=a && sec<b)
        {
         endSec=b+tail;
         return true;
        }
     }
   for(uint idx=0;idx<20;idx++)
     {
      if(!SymbolInfoSessionTrade(sym,(ENUM_DAY_OF_WEEK)prevDow,idx,from,to))
         break;
      if(!SplitSession((long)from,(long)to,a,b,tail))
         continue;
      if(sec<tail)
        {
         endSec=tail;
         return true;
        }
     }
   return false;
  }

string SessionText(const string sym,const datetime serverTime)
  {
   long endSec=0;
   if(FindTradeSession(sym,serverTime,endSec))
      return "检查时刻在交易时段内（该时段于服务器 "+((endSec>=86400) ? "次日 " : "")
             +StringFormat("%02d:%02d",(int)((endSec%86400)/3600),(int)((endSec%3600)/60))+" 结束）";
   return "检查时刻不在交易时段内，请核对收盘时间和时区";
  }

//+------------------------------------------------------------------+
//| 持仓 / 挂单 / 成交查询（只看本EA的 Magic）                         |
//+------------------------------------------------------------------+
ulong FindOwnPosition(const string sym)
  {
   for(int k=PositionsTotal()-1;k>=0;k--)
     {
      ulong t=PositionGetTicket(k);
      if(t==0)
         continue;
      if(PositionGetString(POSITION_SYMBOL)!=sym)
         continue;
      if(PositionGetInteger(POSITION_MAGIC)!=InpMagic)
         continue;
      return t;
     }
   return 0;
  }

bool HasAnyPosition(const string sym)
  {
   for(int k=PositionsTotal()-1;k>=0;k--)
     {
      ulong t=PositionGetTicket(k);
      if(t==0)
         continue;
      if(PositionGetString(POSITION_SYMBOL)==sym)
         return true;
     }
   return false;
  }

bool HasOwnPendingOrder(const string sym)
  {
   for(int k=OrdersTotal()-1;k>=0;k--)
     {
      ulong t=OrderGetTicket(k);
      if(t==0)
         continue;
      if(OrderGetString(ORDER_SYMBOL)!=sym)
         continue;
      if(OrderGetInteger(ORDER_MAGIC)!=InpMagic)
         continue;
      return true;
     }
   return false;
  }

// 返回：1=找到本EA自 fromServer 起的开仓成交；0=没有；-1=无法读取历史
int OwnDealSince(const string sym,const datetime fromServer)
  {
   if(!HistorySelect(fromServer,(datetime)((long)TimeTradeServer()+86400)))
      return -1;
   int total=HistoryDealsTotal();
   for(int k=0;k<total;k++)
     {
      ulong d=HistoryDealGetTicket(k);
      if(d==0)
         continue;
      if(HistoryDealGetString(d,DEAL_SYMBOL)!=sym)
         continue;
      if(HistoryDealGetInteger(d,DEAL_MAGIC)!=InpMagic)
         continue;
      if(HistoryDealGetInteger(d,DEAL_ENTRY)!=DEAL_ENTRY_IN)
         continue;
      if((long)HistoryDealGetInteger(d,DEAL_TIME)<(long)fromServer)
         continue;
      return 1;
     }
   return 0;
  }

//+------------------------------------------------------------------+
//| 参数读取与校验                                                    |
//+------------------------------------------------------------------+
void LoadSlot(const int i,const bool en,const ENUM_EXEC_MODE em,const string sym,const string cd,
              const string ct,const ENUM_TZ tz,const double cOff,
              const int lead,const bool mon,const bool tue,const bool wed,const bool thu,const bool fri,
              const bool sat,const bool sun,const ENUM_COND cond,const double thr,const ENUM_DIR dir,
              const double lots,const double tp,const double sl,
              const ENUM_LOT_MODE lm,const ENUM_STOPS_MODE smode,const double tpd,const double sld)
  {
   g_cfg[i].lotMode       = lm;
   g_cfg[i].stopsMode     = smode;
   g_cfg[i].tpDist        = tpd;
   g_cfg[i].slDist        = sld;
   g_cfg[i].effLots       = 0.0;
   g_cfg[i].enabled       = en;
   g_cfg[i].execMode      = em;
   g_cfg[i].symbol        = sym;
   g_cfg[i].closeDateText = cd;
   g_cfg[i].closeDate     = 0;
   g_cfg[i].closeTimeText = ct;
   g_cfg[i].closeMinutes  = -1;
   g_cfg[i].tz            = tz;
   g_cfg[i].customOffsetH = cOff;
   g_cfg[i].leadMinutes   = lead;
   g_cfg[i].weekdays[0]   = sun;
   g_cfg[i].weekdays[1]   = mon;
   g_cfg[i].weekdays[2]   = tue;
   g_cfg[i].weekdays[3]   = wed;
   g_cfg[i].weekdays[4]   = thu;
   g_cfg[i].weekdays[5]   = fri;
   g_cfg[i].weekdays[6]   = sat;
   g_cfg[i].cond          = cond;
   g_cfg[i].threshold     = thr;
   g_cfg[i].dir           = dir;
   g_cfg[i].lots          = lots;
   g_cfg[i].tp            = tp;
   g_cfg[i].sl            = sl;
   g_cfg[i].valid         = false;
   g_cfg[i].invalidReason = "";
  }

// v1.19 新增参数（单独一个函数，保持 LoadSlot 的参数表与旧版一致）
void LoadSlotExt(const int i,const double rLow,const double rHigh,const double tpm,const double slm,const double maxSp)
  {
   g_cfg[i].rangeLow  = rLow;
   g_cfg[i].rangeHigh = rHigh;
   g_cfg[i].tpMoney   = tpm;
   g_cfg[i].slMoney   = slm;
   g_cfg[i].maxSpread = maxSp;
   g_cfg[i].effTpDist = 0.0;
   g_cfg[i].effSlDist = 0.0;
  }

void LoadAllSlots()
  {
   LoadSlot(0,S1_Enabled,S1_ExecMode,S1_Symbol,S1_CloseDate,S1_CloseTime,S1_TimeZone,S1_CustomOffset,S1_LeadMinutes,
            S1_Mon,S1_Tue,S1_Wed,S1_Thu,S1_Fri,S1_Sat,S1_Sun,S1_Condition,S1_Threshold,S1_Direction,
            S1_Lots,S1_TakeProfit,S1_StopLoss,S1_LotMode,S1_StopsMode,S1_TPDistance,S1_SLDistance);
   LoadSlotExt(0,S1_RangeLow,S1_RangeHigh,S1_TPMoney,S1_SLMoney,S1_MaxSpread);
   LoadSlot(1,S2_Enabled,S2_ExecMode,S2_Symbol,S2_CloseDate,S2_CloseTime,S2_TimeZone,S2_CustomOffset,S2_LeadMinutes,
            S2_Mon,S2_Tue,S2_Wed,S2_Thu,S2_Fri,S2_Sat,S2_Sun,S2_Condition,S2_Threshold,S2_Direction,
            S2_Lots,S2_TakeProfit,S2_StopLoss,S2_LotMode,S2_StopsMode,S2_TPDistance,S2_SLDistance);
   LoadSlotExt(1,S2_RangeLow,S2_RangeHigh,S2_TPMoney,S2_SLMoney,S2_MaxSpread);
   LoadSlot(2,S3_Enabled,S3_ExecMode,S3_Symbol,S3_CloseDate,S3_CloseTime,S3_TimeZone,S3_CustomOffset,S3_LeadMinutes,
            S3_Mon,S3_Tue,S3_Wed,S3_Thu,S3_Fri,S3_Sat,S3_Sun,S3_Condition,S3_Threshold,S3_Direction,
            S3_Lots,S3_TakeProfit,S3_StopLoss,S3_LotMode,S3_StopsMode,S3_TPDistance,S3_SLDistance);
   LoadSlotExt(2,S3_RangeLow,S3_RangeHigh,S3_TPMoney,S3_SLMoney,S3_MaxSpread);
   LoadSlot(3,S4_Enabled,S4_ExecMode,S4_Symbol,S4_CloseDate,S4_CloseTime,S4_TimeZone,S4_CustomOffset,S4_LeadMinutes,
            S4_Mon,S4_Tue,S4_Wed,S4_Thu,S4_Fri,S4_Sat,S4_Sun,S4_Condition,S4_Threshold,S4_Direction,
            S4_Lots,S4_TakeProfit,S4_StopLoss,S4_LotMode,S4_StopsMode,S4_TPDistance,S4_SLDistance);
   LoadSlotExt(3,S4_RangeLow,S4_RangeHigh,S4_TPMoney,S4_SLMoney,S4_MaxSpread);
   LoadSlot(4,S5_Enabled,S5_ExecMode,S5_Symbol,S5_CloseDate,S5_CloseTime,S5_TimeZone,S5_CustomOffset,S5_LeadMinutes,
            S5_Mon,S5_Tue,S5_Wed,S5_Thu,S5_Fri,S5_Sat,S5_Sun,S5_Condition,S5_Threshold,S5_Direction,
            S5_Lots,S5_TakeProfit,S5_StopLoss,S5_LotMode,S5_StopsMode,S5_TPDistance,S5_SLDistance);
   LoadSlotExt(4,S5_RangeLow,S5_RangeHigh,S5_TPMoney,S5_SLMoney,S5_MaxSpread);
  }

// 从当前账户的品种规格读取最小手数。返回空字符串表示成功（lots 为最小手数），否则返回原因
string ReadMinLot(const string sym,double &lots)
  {
   lots=0.0;
   double vmin=0.0,vstep=0.0,vmax=0.0;
   ResetLastError();
   if(!SymbolInfoDouble(sym,SYMBOL_VOLUME_MIN,vmin) || !SymbolInfoDouble(sym,SYMBOL_VOLUME_STEP,vstep)
      || !SymbolInfoDouble(sym,SYMBOL_VOLUME_MAX,vmax))
      return "读取该品种手数规格失败（错误码 "+IntegerToString(GetLastError())+"）";
   if(vmin<=0.0)
      return "该品种最小手数读取值无效（"+NumStr(vmin)+"）";
   if(vstep<=0.0)
      return "该品种手数步长读取值无效（"+NumStr(vstep)+"）";
   if(vmax>0.0 && vmin>vmax+1e-9)
      return "该品种最小手数 "+NumStr(vmin)+" 大于最大手数 "+NumStr(vmax)+"，规格异常";
   double n=vmin/vstep;
   if(MathAbs(n-MathRound(n))>1e-6)
      return "该品种最小手数 "+NumStr(vmin)+" 不是手数步长 "+NumStr(vstep)+" 的整数倍，规格异常";
   lots=vmin;
   return "";
  }

// 按品种最小价格变动取整到最近的价位
double RoundToTick(const string sym,const double price)
  {
   double ts=TickSize(sym);
   int digits=(int)SymbolInfoInteger(sym,SYMBOL_DIGITS);
   if(ts<=0.0)
      return NormalizeDouble(price,digits);
   return NormalizeDouble(MathRound(price/ts)*ts,digits);
  }

// 计算本次下单使用的止盈止损。固定价格模式：直接使用填写的价格；
// 价格差模式：买入以 Ask、卖出以 Bid 为预计开仓价，加减距离后按最小价格变动取整（距离本身须为最小变动的整数倍）。
// v1.19 金额模式：先用 OrderCalcProfit 把金额换算为距离（note 返回换算说明），之后与价格差模式相同。
string ComputeStops(const int i,const MqlTick &tk,double &sl,double &tp,string &note)
  {
   note="";
   string sym=g_cfg[i].symbol;
   int digits=(int)SymbolInfoInteger(sym,SYMBOL_DIGITS);
   if(!StopsByDist(i))
     {
      sl=NormalizeDouble(g_cfg[i].sl,digits);
      tp=NormalizeDouble(g_cfg[i].tp,digits);
      return "";
     }
   if(TickSize(sym)<=0.0)
      return "无法读取该品种的最小价格变动";
   bool   isBuy=(g_cfg[i].dir==DIR_BUY);
   double ref=isBuy ? tk.ask : tk.bid;
   string r="";
   if(g_cfg[i].stopsMode==STOPS_MONEY)
     {
      double td=0.0,sd=0.0;
      r=MoneyToDistances(i,g_cfg[i].effLots,ref,td,sd,note);
      if(r!="")
         return r;
      g_cfg[i].effTpDist=td;
      g_cfg[i].effSlDist=sd;
     }
   else
     {
      r=CheckPriceStep(sym,g_cfg[i].tpDist,"止盈距离");
      if(r!="")
         return r;
      r=CheckPriceStep(sym,g_cfg[i].slDist,"止损距离");
      if(r!="")
         return r;
     }
   tp=RoundToTick(sym,isBuy ? ref+EffTpDist(i) : ref-EffTpDist(i));
   sl=RoundToTick(sym,isBuy ? ref-EffSlDist(i) : ref+EffSlDist(i));
   if(sl<=0.0 || tp<=0.0)
      return "按价格差计算出的止盈/止损价格无效（止盈 "+P(sym,tp)+"，止损 "+P(sym,sl)+"）";
   return "";
  }

// 止盈止损相对当前报价的方向与券商最小止损距离检查（不修改价格）
string CheckStopsVsTick(const string sym,const bool isBuy,const MqlTick &tk,const double sl,const double tp)
  {
   double point=SymbolInfoDouble(sym,SYMBOL_POINT);
   int    stopsLevel=(int)SymbolInfoInteger(sym,SYMBOL_TRADE_STOPS_LEVEL);
   double minDist=stopsLevel*point;
   double tol=point*0.01;
   string distNote=(stopsLevel>0) ? "，且距离至少 "+IntegerToString(stopsLevel)+" 点（券商最小止损距离）" : "";
   if(isBuy)
     {
      if(!(sl<tk.bid) || (tk.bid-sl)<minDist-tol)
         return "止损价 "+P(sym,sl)+" 不合法：买单止损须低于当前 Bid "+P(sym,tk.bid)+distNote;
      if(!(tp>tk.bid) || (tp-tk.bid)<minDist-tol)
         return "止盈价 "+P(sym,tp)+" 不合法：买单止盈须高于当前 Bid "+P(sym,tk.bid)+distNote;
     }
   else
     {
      if(!(sl>tk.ask) || (sl-tk.ask)<minDist-tol)
         return "止损价 "+P(sym,sl)+" 不合法：卖单止损须高于当前 Ask "+P(sym,tk.ask)+distNote;
      if(!(tp<tk.ask) || (tk.ask-tp)<minDist-tol)
         return "止盈价 "+P(sym,tp)+" 不合法：卖单止盈须低于当前 Ask "+P(sym,tk.ask)+distNote;
     }
   return "";
  }

string CheckLots(const string sym,const double lots)
  {
   double vmin=SymbolInfoDouble(sym,SYMBOL_VOLUME_MIN);
   double vmax=SymbolInfoDouble(sym,SYMBOL_VOLUME_MAX);
   double vstep=SymbolInfoDouble(sym,SYMBOL_VOLUME_STEP);
   if(lots<vmin-1e-9)
      return "手数 "+NumStr(lots)+" 小于该品种最小手数 "+NumStr(vmin);
   if(vmax>0.0 && lots>vmax+1e-9)
      return "手数 "+NumStr(lots)+" 大于该品种最大手数 "+NumStr(vmax);
   if(vstep>0.0)
     {
      double n=lots/vstep;
      if(MathAbs(n-MathRound(n))>1e-6)
         return "手数 "+NumStr(lots)+" 不符合该品种手数步长 "+NumStr(vstep);
     }
   return "";
  }

string CheckPriceStep(const string sym,const double price,const string name)
  {
   double ts=TickSize(sym);
   if(ts<=0.0)
      return "无法读取该品种的最小价格变动";
   double n=price/ts;
   if(MathAbs(n-MathRound(n))>1e-4)
      return name+" "+NumStr(price)+" 不是该品种最小价格变动 "+NumStr(ts)+" 的整数倍";
   return "";
  }

string CheckSlotParams(const int i)
  {
   string sym=g_cfg[i].symbol;
   if(StringLen(sym)==0)
      return "未填写品种名称";
   bool isCustom=false;
   if(!SymbolExist(sym,isCustom))
      return "找不到品种 ["+sym+"]（方括号内为实际填写内容，请核对大小写、后缀、首尾空格）";
   if(!SymbolSelect(sym,true))
      return "无法把品种 ["+sym+"] 加入“市场报价”";
   int mins=-1;
   if(!ParseHHMM(g_cfg[i].closeTimeText,mins))
      return "收盘时间格式无效：["+g_cfg[i].closeTimeText+"]，应为 HH:MM，例如 16:00";
   g_cfg[i].closeMinutes=mins;
   if(g_cfg[i].execMode==EXEC_ONCE)
     {
      datetime d=0;
      if(!ParseDate(g_cfg[i].closeDateText,d))
         return "一次性任务的目标收盘日期无效：["+g_cfg[i].closeDateText+"]，应为 YYYY.MM.DD，例如 2026.10.24";
      g_cfg[i].closeDate=d;
     }
   if(g_cfg[i].tz==TZ_CUSTOM)
     {
      double x=g_cfg[i].customOffsetH;
      if(x<-12.0 || x>14.0)
         return "自定义UTC偏移需在 -12 到 +14 小时之间";
      if(MathAbs(x*4.0-MathRound(x*4.0))>1e-9)
         return "自定义UTC偏移需为 0.25 小时（15分钟）的整数倍";
     }
   if(g_cfg[i].leadMinutes<1 || g_cfg[i].leadMinutes>720)
      return "提前检查分钟数需在 1–720 之间";
   if(InpGraceSeconds>=g_cfg[i].leadMinutes*60)
      return "容错窗口（"+IntegerToString(InpGraceSeconds)+"秒）必须小于提前检查时间，否则窗口会越过收盘时刻";
   if(g_cfg[i].execMode==EXEC_WEEKLY)
     {
      bool anyDay=false;
      for(int k=0;k<7;k++)
         if(g_cfg[i].weekdays[k])
            anyDay=true;
      if(!anyDay)
         return "按星期重复模式下未勾选任何执行星期";
     }
   if(g_cfg[i].cond!=COND_GTE && g_cfg[i].cond!=COND_LTE && g_cfg[i].cond!=COND_ALWAYS && g_cfg[i].cond!=COND_RANGE)
      return "未设置开仓条件（≥、≤、价格区间 或 到点直接执行）";
   if(g_cfg[i].dir!=DIR_BUY && g_cfg[i].dir!=DIR_SELL)
      return "未设置开仓方向（买入或卖出）";
   if((g_cfg[i].cond==COND_GTE || g_cfg[i].cond==COND_LTE) && g_cfg[i].threshold<=0.0)
      return "触发阈值必须大于 0（“到点直接执行”不需要阈值）";
   if(g_cfg[i].cond==COND_RANGE)
     {
      if(g_cfg[i].rangeLow<=0.0 || g_cfg[i].rangeHigh<=0.0)
         return "价格区间条件下，区间最低价和最高价都必须填写且大于 0";
      if(!(g_cfg[i].rangeLow<g_cfg[i].rangeHigh))
         return "价格区间的最高价（"+NumStr(g_cfg[i].rangeHigh)+"）必须大于最低价（"+NumStr(g_cfg[i].rangeLow)+"）";
     }
   if(g_cfg[i].maxSpread<0.0)
      return "最大允许点差不能为负数（0 表示不限制）";
   string r="";
   if(g_cfg[i].lotMode==LOT_FIXED)
     {
      if(g_cfg[i].lots<=0.0)
         return "手数必须大于 0";
      r=CheckLots(sym,g_cfg[i].lots);
      if(r!="")
         return r;
     }
   else
      if(g_cfg[i].lotMode!=LOT_MIN)
         return "手数模式无效";
   if(g_cfg[i].stopsMode==STOPS_DISTANCE)
     {
      if(g_cfg[i].tpDist<=0.0)
         return "止盈距离为必填项，必须大于 0";
      if(g_cfg[i].slDist<=0.0)
         return "止损距离为必填项，必须大于 0";
      r=CheckPriceStep(sym,g_cfg[i].tpDist,"止盈距离");
      if(r!="")
         return r;
      r=CheckPriceStep(sym,g_cfg[i].slDist,"止损距离");
      if(r!="")
         return r;
      return "";
     }
   if(g_cfg[i].stopsMode==STOPS_MONEY)
     {
      if(g_cfg[i].tpMoney<=0.0)
         return "止盈金额为必填项，必须大于 0";
      if(g_cfg[i].slMoney<=0.0)
         return "止损金额为必填项，必须大于 0";
      return "";
     }
   if(g_cfg[i].stopsMode!=STOPS_PRICE)
      return "止盈止损模式无效";
   if(g_cfg[i].tp<=0.0)
      return "止盈价格为必填项，必须大于 0";
   if(g_cfg[i].sl<=0.0)
      return "止损价格为必填项，必须大于 0";
   r=CheckPriceStep(sym,g_cfg[i].tp,"止盈价");
   if(r!="")
      return r;
   r=CheckPriceStep(sym,g_cfg[i].sl,"止损价");
   if(r!="")
      return r;
   if(g_cfg[i].dir==DIR_BUY && !(g_cfg[i].sl<g_cfg[i].tp))
      return "买入时止损价必须低于止盈价";
   if(g_cfg[i].dir==DIR_SELL && !(g_cfg[i].sl>g_cfg[i].tp))
      return "卖出时止损价必须高于止盈价";
   return "";
  }

// 不阻止运行、但值得提醒的情况
void LogSlotWarnings(const int i)
  {
   string sym=g_cfg[i].symbol;
   string tag=SlotTag(i);
   double thr=g_cfg[i].threshold;
   if(g_cfg[i].lotMode==LOT_MIN)
     {
      double ml=0.0;
      string lr=ReadMinLot(sym,ml);
      Log(tag+((lr=="") ? " 手数模式：品种最小手数，当前读取值 "+NumStr(ml)+" 手（步长 "+NumStr(SymbolInfoDouble(sym,SYMBOL_VOLUME_STEP))
                          +"）；检查时会重新读取"
                        : " 提示：当前无法读取最小手数（"+lr+"）；检查时会重新读取，届时仍失败则跳过"));
     }
   if(g_cfg[i].stopsMode==STOPS_DISTANCE)
     {
      MqlTick t0;
      double point=SymbolInfoDouble(sym,SYMBOL_POINT);
      long   lvl=SymbolInfoInteger(sym,SYMBOL_TRADE_STOPS_LEVEL);
      string sp=(SymbolInfoTick(sym,t0) && t0.ask>=t0.bid && t0.bid>0.0) ? P(sym,t0.ask-t0.bid) : "暂无报价";
      Log(tag+" 止盈止损模式：价格差（止盈 "+NumStr(g_cfg[i].tpDist)+"，止损 "+NumStr(g_cfg[i].slDist)
          +"）。最小价格变动 "+NumStr(TickSize(sym))+"，当前点差 "+sp+"，券商最小止损距离 "+IntegerToString(lvl)
          +" 点（= "+NumStr(lvl*point)+" 价格单位）。买单止损/止盈按 Bid 触发、卖单按 Ask 触发；"
          +"若 距离 − 点差 小于最小止损距离，届时会跳过，不会自动放大距离");
     }
   if(g_cfg[i].stopsMode==STOPS_MONEY)
     {
      // 仅作预览：按当前报价和当前手数换算一次，检查时与发单前都会按届时报价重新换算
      MqlTick t1;
      double  pl=g_cfg[i].lots;
      string  pv="";
      if(g_cfg[i].lotMode==LOT_MIN && ReadMinLot(sym,pl)!="")
         pv="当前无法读取最小手数，暂不能预览换算";
      else
         if(!SymbolInfoTick(sym,t1) || t1.bid<=0.0 || t1.ask<=0.0)
            pv="暂无报价，暂不能预览换算";
         else
           {
            double td=0.0,sd=0.0;
            string nt="";
            string mr=MoneyToDistances(i,pl,(g_cfg[i].dir==DIR_BUY) ? t1.ask : t1.bid,td,sd,nt);
            pv=(mr=="") ? "按当前报价预览 "+nt : "按当前报价预览换算未通过："+mr;
           }
      Log(tag+" 止盈止损模式：账户货币金额（盈利 "+NumStr(g_cfg[i].tpMoney)+" / 亏损 "+NumStr(g_cfg[i].slMoney)+" "
          +AccountInfoString(ACCOUNT_CURRENCY)+"）。"+pv
          +"。说明：金额按开仓价到止盈/止损价的价格距离换算；开仓时已付出的点差、止损成交滑点、手续费、隔夜利息"
          +"会使实际盈亏偏离目标金额；止损向下取整到最小价格变动（理论亏损不超过目标），止盈取最接近的价位");
     }
   if(g_cfg[i].maxSpread>0.0)
      Log(tag+" 最大允许点差："+NumStr(g_cfg[i].maxSpread)+"（价格单位，Ask−Bid）。检查时和发单前各检查一次，超限不下单、不重试");
   if(g_cfg[i].cond==COND_RANGE)
      Log(tag+" 开仓条件：价格区间 "+CondDesc(i)+"。上下限须同时满足；检查时判断一次，发单前按最新报价再复核一次，任一次不满足都不下单");
   if(g_cfg[i].cond==COND_ALWAYS)
      Log(tag+" 开仓条件：到点直接执行。检查时刻之前不会下单；到点后除价格阈值外，其余检查全部照常");
   if(g_cfg[i].cond==COND_ALWAYS || g_cfg[i].stopsMode!=STOPS_PRICE)
     {
      for(int j=0;j<i;j++)
         if(g_cfg[j].enabled && g_cfg[j].valid && g_cfg[j].symbol==sym)
            Log(tag+" 提示：与品种"+IntegerToString(j+1)+" 使用同一品种；已有本EA持仓时后触发的一组会跳过");
      return;   // 下面的“阈值与固定止盈止损”提示不适用
     }
   if(g_cfg[i].cond==COND_RANGE)
     {
      // 价格区间 + 固定止盈止损价：提示必然无效的组合
      if(g_cfg[i].dir==DIR_BUY)
        {
         if(g_cfg[i].tp<=g_cfg[i].rangeLow)
            Log(tag+" 警告：买入且止盈价不高于区间最低价，条件满足时止盈必然无效，届时会跳过");
         if(g_cfg[i].sl>=g_cfg[i].rangeHigh)
            Log(tag+" 警告：买入且止损价不低于区间最高价，条件满足时止损必然无效，届时会跳过");
        }
      else
        {
         if(g_cfg[i].sl<=g_cfg[i].rangeLow)
            Log(tag+" 警告：卖出且止损价不高于区间最低价，条件满足时止损必然无效，届时会跳过");
         if(g_cfg[i].tp>=g_cfg[i].rangeHigh)
            Log(tag+" 警告：卖出且止盈价不低于区间最高价，条件满足时止盈几乎必然无效，届时会跳过");
        }
      for(int j=0;j<i;j++)
         if(g_cfg[j].enabled && g_cfg[j].valid && g_cfg[j].symbol==sym)
            Log(tag+" 提示：与品种"+IntegerToString(j+1)+" 使用同一品种；已有本EA持仓时后触发的一组会跳过");
      return;
     }
   if(CheckPriceStep(sym,thr,"阈值")!="")
      Log(tag+" 提示：阈值 "+NumStr(thr)+" 不是最小价格变动的整数倍（只用于比较，不影响下单，但请确认是否填错）");
   if(g_cfg[i].dir==DIR_BUY)
     {
      if(g_cfg[i].cond==COND_GTE && g_cfg[i].tp<=thr)
         Log(tag+" 警告：买入且条件为“≥阈值”，但止盈价不高于阈值，条件满足时止盈几乎必然无效，届时会跳过");
      if(g_cfg[i].cond==COND_LTE && g_cfg[i].sl>=thr)
         Log(tag+" 警告：买入且条件为“≤阈值”，但止损价不低于阈值，条件满足时止损几乎必然无效，届时会跳过");
     }
   else
     {
      if(g_cfg[i].cond==COND_GTE && g_cfg[i].sl<=thr)
         Log(tag+" 警告：卖出且条件为“≥阈值”，但止损价不高于阈值，条件满足时止损几乎必然无效，届时会跳过");
      if(g_cfg[i].cond==COND_LTE && g_cfg[i].tp>=thr)
         Log(tag+" 警告：卖出且条件为“≤阈值”，但止盈价不低于阈值，条件满足时止盈几乎必然无效，届时会跳过");
     }
   for(int j=0;j<i;j++)
      if(g_cfg[j].enabled && g_cfg[j].valid && g_cfg[j].symbol==sym)
         Log(tag+" 提示：与品种"+IntegerToString(j+1)+" 使用同一品种；已有本EA持仓时后触发的一组会跳过");
  }

string ValidateGlobals()
  {
   if(InpMagic<=0)
      return "Magic Number 必须为正整数";
   if(InpGraceSeconds<1 || InpGraceSeconds>600)
      return "容错窗口需在 1–600 秒之间";
   if(InpMaxTimerGapSec<2 || InpMaxTimerGapSec>60)
      return "定时器允许的最大停顿需在 2–60 秒之间";
   if(InpMaxQuoteAgeSec<1 || InpMaxQuoteAgeSec>3600)
      return "报价过期秒数需在 1–3600 之间";
   if(InpDeviationPoints<0)
      return "允许滑点不能为负数";
   if(InpServerTzMode==SERVER_TZ_MANUAL)
     {
      if(InpServerUtcOffsetHours<-12.0 || InpServerUtcOffsetHours>14.0)
         return "手动服务器UTC偏移需在 -12 到 +14 小时之间";
     }
   return "";
  }

//+------------------------------------------------------------------+
//| 事件（某品种某天的一次检查）                                       |
//+------------------------------------------------------------------+
datetime LocalDayStart(const int i,const datetime nowUtc)
  {
   long nowLocal=(long)nowUtc+ZoneOffsetAtUtc(g_cfg[i].tz,g_cfg[i].customOffsetH,nowUtc);
   return (datetime)(nowLocal-(nowLocal%86400));
  }

// 根据“当地日期 + 收盘时间”生成一个事件。事件编号格式与 v1.00 完全相同（兼容旧记录）：
// SCE_<Magic>_<品种组号>_<当地日期YYYYMMDD>_<收盘HHMM>
void BuildEvent(const int i,const datetime localDate,EventInfo &ev)
  {
   datetime closeLocal=(datetime)((long)localDate+g_cfg[i].closeMinutes*60);
   ev.localDate=localDate;
   ev.closeUtc=LocalToUtc(g_cfg[i].tz,g_cfg[i].customOffsetH,closeLocal);
   ev.checkUtc=(datetime)((long)ev.closeUtc-g_cfg[i].leadMinutes*60);   // 跨午夜由时间相减自然处理
   ev.key=GV_PREFIX+IntegerToString(InpMagic)+"_"+IntegerToString(i+1)+"_"+DateKey(localDate)
          +"_"+StringFormat("%02d%02d",g_cfg[i].closeMinutes/60,g_cfg[i].closeMinutes%60);
  }

// 按星期重复模式：该日期是否为勾选的执行日
bool GetEvent(const int i,const datetime localDate,EventInfo &ev)
  {
   int wd=DayOfWeek(localDate);
   if(!g_cfg[i].weekdays[wd])
      return false;
   BuildEvent(i,localDate,ev);
   return true;
  }

// 一次性模式：唯一的事件（忽略星期勾选）
void GetOnceEvent(const int i,EventInfo &ev)
  {
   BuildEvent(i,g_cfg[i].closeDate,ev);
  }

// 按星期重复模式：下一个尚未处理的事件
bool FindNextEvent(const int i,const datetime nowUtc,EventInfo &ev)
  {
   datetime today=LocalDayStart(i,nowUtc);
   for(int dd=-1;dd<=8;dd++)
     {
      if(!GetEvent(i,(datetime)((long)today+dd*86400),ev))
         continue;
      if((long)ev.checkUtc+InpGraceSeconds>=(long)nowUtc && !IsEventDone(ev.key))
         return true;
     }
   return false;
  }

string ScheduleText(const int i,EventInfo &ev)
  {
   datetime closeLocal=(datetime)((long)ev.localDate+g_cfg[i].closeMinutes*60);
   datetime checkServer=(datetime)((long)ev.checkUtc+g_serverOffsetSec);
   return "目标收盘 "+FmtDTm(closeLocal)+"（"+TzName(i)+"）"
          +" | 检查 北京 "+FmtDTm((datetime)((long)ev.checkUtc+8*3600))
          +" / 服务器≈ "+FmtDTm(checkServer)
          +"（提前"+IntegerToString(g_cfg[i].leadMinutes)+"分钟）"
          +" | "+SessionText(g_cfg[i].symbol,checkServer);
  }

void LogScheduleIfChanged(const int i,const datetime nowUtc)
  {
   EventInfo ev;
   if(g_cfg[i].execMode==EXEC_ONCE)
     {
      GetOnceEvent(i,ev);
      if(ev.key==g_st[i].scheduleKey)
         return;
      g_st[i].scheduleKey=ev.key;
      Log(SlotTag(i)+" 一次性任务："+ScheduleText(i,ev)+" | 状态："+EventStatusText(i,ev,nowUtc)
          +" | 事件 "+ev.key);
      return;
     }
   if(!FindNextEvent(i,nowUtc,ev))
     {
      if(g_st[i].scheduleKey!="none")
        {
         g_st[i].scheduleKey="none";
         Log(SlotTag(i)+" 未来8天内没有勾选的执行日");
        }
      return;
     }
   if(ev.key==g_st[i].scheduleKey)
      return;
   g_st[i].scheduleKey=ev.key;
   Log(SlotTag(i)+" 按星期重复，下一次："+ScheduleText(i,ev));
  }

// 写入事件状态：检查 GlobalVariableSet 的写入结果 -> 调用 GlobalVariablesFlush 强制保存（该函数无返回值）
// -> 读回核对。读回只能证明终端内存中的值正确，不能独立证明已写入磁盘；不能检测所有落盘失败。
// 写入结果失败或读回不一致时返回 false 并报警。
bool WriteEventState(const string key,const int state)
  {
   ResetLastError();
   datetime r=GlobalVariableSet(key,(double)state);
   int err=GetLastError();
   GlobalVariablesFlush();
   bool ok=(r!=0 && GlobalVariableCheck(key) && (int)MathRound(GlobalVariableGet(key))==state);
   if(!ok)
     {
      string m="严重：防重复记录写入失败 "+key+" 目标状态="+IntegerToString(state)
               +"（"+StateText(state)+"），错误码 "+IntegerToString(err)
               +"。本实例将不再处理该任务；请检查 MT5 全局变量（F3）和磁盘空间/权限";
      Log(m);
      Alert(m);
     }
   return ok;
  }

int BlockedIndex(const string key)
  {
   int n=ArraySize(g_blockedKeys);
   for(int k=0;k<n;k++)
      if(g_blockedKeys[k]==key)
         return k;
   return -1;
  }

// 在本实例内封锁任务（记录写入失败时使用），之后的定时器周期不再处理它
void BlockKey(const string key,const int state)
  {
   int k=BlockedIndex(key);
   if(k<0)
     {
      k=ArraySize(g_blockedKeys);
      ArrayResize(g_blockedKeys,k+1);
      ArrayResize(g_blockedStates,k+1);
      g_blockedKeys[k]=key;
     }
   g_blockedStates[k]=state;
  }

bool IsEventDone(const string key)
  {
   return (GlobalVariableCheck(key) || BlockedIndex(key)>=0);
  }

// 记录事件结果（先写入全局变量、调用强制保存并读回核对，再写日志）
void RecordEvent(const int i,EventInfo &ev,const int state,const string summary,const string detail)
  {
   bool saved=WriteEventState(ev.key,state);
   if(!saved)
      BlockKey(ev.key,state);
   string msg=SlotTag(i)+" 【"+summary+"】 检查时刻：北京 "+FmtDT((datetime)((long)ev.checkUtc+8*3600))
              +" / 服务器≈ "+FmtDT((datetime)((long)ev.checkUtc+g_serverOffsetSec))+" | 事件 "+ev.key;
   if(detail!="")
      msg+=" | "+detail;
   if(!saved)
      msg+=" | 警告：本结果未能写入全局变量（重启后无此记录），本实例已封锁该任务";
   Log(msg);
   g_st[i].lastResult=FmtDTm((datetime)((long)ev.checkUtc+8*3600))+"(北京) "+summary;
   // v1.19：面板“本次结果”行（仅本实例内存，重新加载后以日志为准）
   string li=summary;
   string f=DetailField(detail,"判断用价 ");
   if(f=="")
      f=DetailField(detail,"参考价 ");
   if(f!="")
      li+=" | "+f;
   f=DetailField(detail,"点差=");
   if(f!="")
      li+=" | "+f;
   f=DetailField(detail,"原因：");
   if(f!="")
      li+=" | "+f;
   g_st[i].lastInfo=li;
   g_st[i].lastInfoKey=ev.key;
  }

void SetRetry(const int i,EventInfo &ev,const string reason)
  {
   g_st[i].retryReason=reason;
   if(g_st[i].retryLoggedKey!=ev.key)
     {
      g_st[i].retryLoggedKey=ev.key;
      Log(SlotTag(i)+" 检查时刻已到，但"+reason+"；将在容错窗口（"+IntegerToString(InpGraceSeconds)
          +"秒）内继续尝试取得有效报价，取得后只判断一次");
     }
  }

//+------------------------------------------------------------------+
//| 每个定时器周期处理一个品种                                         |
//+------------------------------------------------------------------+
void ProcessSlot(const int i,const datetime nowUtc,const bool connected)
  {
   if(g_cfg[i].execMode==EXEC_ONCE)
     {
      // 一次性：只处理这一个事件；处理完（任何结果）即结束，绝不顺延到其他日期
      EventInfo ev;
      GetOnceEvent(i,ev);
      ProcessEvent(i,ev,nowUtc,connected);
      return;
     }
   datetime today=LocalDayStart(i,nowUtc);
   for(int dd=-1;dd<=1;dd++)
     {
      EventInfo ev;
      if(!GetEvent(i,(datetime)((long)today+dd*86400),ev))
         continue;
      ProcessEvent(i,ev,nowUtc,connected);
     }
  }

void ProcessEvent(const int i,EventInfo &ev,const datetime nowUtc,const bool connected)
  {
   bool once=(g_cfg[i].execMode==EXEC_ONCE);
   long now=(long)nowUtc;
   long chk=(long)ev.checkUtc;
   long windowEnd=chk+InpGraceSeconds;

   // 检查时刻之前：在最后 ARM_SECONDS 秒内，若EA正常运行且已连接，则标记为“就绪”
   // （此前无论当下价格如何，都不做判断、不下单）
   if(now<chk)
     {
      if(chk-now<=ARM_SECONDS)
        {
         bool settled=(g_runStartUtc!=0 && (long)nowUtc-(long)g_runStartUtc>=MIN_CONTINUOUS_SECONDS);
         if(connected && settled)
           {
            if(g_st[i].armedKey!=ev.key)
               g_st[i].retryReason="窗口内未能执行检查（终端繁忙或定时器延迟）";
            g_st[i].armedKey=ev.key;
           }
         else
            g_st[i].armedKey="";
        }
      return;
     }

   // 已处理过的事件（含终端重启、重新加载、修改参数前处理过的；以及本实例内记录写入失败而封锁的）直接跳过
   if(IsEventDone(ev.key))
      return;

   // 已超出容错窗口
   if(now>windowEnd)
     {
      // 一次性任务无论多久以前都记录为“已错过”（持久结束）；重复模式只记录最近12小时内的，避免启动时刷屏
      if(once || now-chk<=12*3600)
        {
         string why;
         if(g_st[i].armedKey==ev.key)
            why="容错窗口内未取得有效报价，本次不交易："+g_st[i].retryReason;
         else
            if(once)
               why="一次性任务的检查时刻已过（设置/加载时已过期，或检查时刻EA未在运行），任务结束，不补单、不顺延";
            else
               why="检查时刻EA未在正常运行（启动/重启/断线恢复时已错过），按规则跳过，不补单";
         RecordEvent(i,ev,ST_MISSED,"已错过",why);
        }
      return;
     }

   // 处于容错窗口内
   if(g_st[i].armedKey!=ev.key)
     {
      RecordEvent(i,ev,ST_MISSED,"已错过",
                  "检查时刻之前EA未处于正常运行状态（刚启动/刚重启/断线刚恢复/参数刚修改），按规则跳过，不补单"
                  +(once ? "；一次性任务就此结束，不顺延" : ""));
      return;
     }
   if(!connected)
     {
      RecordEvent(i,ev,ST_SKIPPED,"跳过","检查时段内终端与服务器断开连接");
      return;
     }
   if(!g_offsetOk)
     {
      RecordEvent(i,ev,ST_SKIPPED,"跳过","服务器时间偏移异常，无法可靠判断时间");
      return;
     }
   RunCheck(i,ev);
  }

//+------------------------------------------------------------------+
//| 一次检查：取报价 -> 判断 -> （满足时）下单前检查 -> 下单            |
//+------------------------------------------------------------------+
void RunCheck(const int i,EventInfo &ev)
  {
   string sym=g_cfg[i].symbol;
   bool   isBuy=(g_cfg[i].dir==DIR_BUY);

   if(!SymbolSelect(sym,true))
     {
      RecordEvent(i,ev,ST_SKIPPED,"跳过","无法在“市场报价”中选中该品种");
      return;
     }

   // 1) 取有效报价（报价无效/过期时，在容错窗口内继续尝试）
   MqlTick tk;
   if(!SymbolInfoTick(sym,tk) || tk.bid<=0.0 || tk.ask<=0.0 || tk.ask<tk.bid)
     {
      SetRetry(i,ev,"暂时取不到有效报价");
      return;
     }
   long age=(long)TimeTradeServer()-(long)tk.time;
   if(age>InpMaxQuoteAgeSec)
     {
      SetRetry(i,ev,"最新报价已 "+IntegerToString(age)+" 秒未更新（上限 "+IntegerToString(InpMaxQuoteAgeSec)
               +" 秒），可能已休市或行情中断");
      return;
     }

   // 2) 判断条件（取得有效报价后，检查阶段只判断这一次；v1.19 起发单前还会按最新报价复核一次）
   double price=isBuy ? tk.ask : tk.bid;
   bool   met=PriceCondMet(i,price);              // 到点直接执行：恒为 true，其余检查照常
   string qn=QuoteName(g_cfg[i].dir);
   string detail="方向="+DirText(g_cfg[i].dir)+" 手数模式="+LotsDesc(i)
                 +" | "+((g_cfg[i].cond==COND_ALWAYS) ? "参考价 " : "判断用价 ")+qn+"="+P(sym,price)
                 +"（Bid="+P(sym,tk.bid)+" Ask="+P(sym,tk.ask)+"，报价时间 服务器 "
                 +TimeToString(tk.time,TIME_DATE|TIME_SECONDS)+"）"
                 +" | "+SpreadDesc(i,tk)
                 +" | 条件 "+CondDesc(i)
                 +" | 判断="+((g_cfg[i].cond==COND_ALWAYS) ? "不判断价格" : (met ? "满足" : "不满足"))
                 +" | 设定 "+StopsDesc(i);

   if(!met)
     {
      RecordEvent(i,ev,ST_NOT_MET,"条件不满足，本次不交易",detail+" | 原因：价格条件不满足（"+qn+"="+P(sym,price)
                  +"，要求 "+CondDesc(i)+"）");
      return;
     }

   // 2a) 最大允许点差（v1.19）：超限不下单，不在窗口内重试
   string spr=SpreadCheck(i,tk);
   if(spr!="")
     {
      RecordEvent(i,ev,ST_SKIPPED,"条件满足但点差超限，未下单",detail+" | 原因："+spr);
      return;
     }

   // 2b) 确定本次手数（最小手数模式：从当前账户品种规格读取，读取失败则跳过）
   double lots=g_cfg[i].lots;
   if(g_cfg[i].lotMode==LOT_MIN)
     {
      string lr=ReadMinLot(sym,lots);
      if(lr!="")
        {
         RecordEvent(i,ev,ST_SKIPPED,"未下单：无法确定最小手数",detail+" | 原因："+lr);
         return;
        }
     }
   g_cfg[i].effLots=lots;
   detail+=" | 本次手数="+NumStr(lots);

   // 2c) 计算本次止盈止损（价格差/金额模式按当前 Ask/Bid 计算，发单前会按最新报价重算，成交后按实际成交价核对）
   double sl=0.0,tp=0.0;
   string mnote="";
   string sr=ComputeStops(i,tk,sl,tp,mnote);
   if(sr!="")
     {
      RecordEvent(i,ev,ST_SKIPPED,"条件满足但未下单",detail+" | 原因："+sr);
      return;
     }
   if(mnote!="")
      detail+=" | "+mnote;
   if(StopsByDist(i))
      detail+=" | 按当前报价计算 止盈="+P(sym,tp)+" 止损="+P(sym,sl);

   // 3) 下单前本地检查
   string reason=PreTradeCheck(i,ev,tk,sl,tp);
   if(reason!="")
     {
      RecordEvent(i,ev,ST_SKIPPED,"条件满足但未下单",detail+" | 原因："+reason);
      return;
     }

   if(InpRunMode!=RUN_TRADE)
     {
      RecordEvent(i,ev,ST_SIGNAL,"仅记录信号（未下单）",
                  detail+" | 下单前本地检查均通过；若为“允许交易”模式，将以市价单开仓（未做服务器预检）。"
                  +"注意：本任务到此结束，之后改为允许交易也不会再执行");
      return;
     }

   // 4) 交易权限 + 服务器预检
   reason=PermissionCheck();
   if(reason=="")
      reason=ServerPreCheck(i,tk,sl,tp);
   if(reason!="")
     {
      RecordEvent(i,ev,ST_SKIPPED,"条件满足但未下单",detail+" | 原因："+reason);
      return;
     }

   // 5) 发单前复核：前面的检查（含服务器预检）可能耗时，必须用最新时间重新确认仍在检查窗口内
   ContinuityCheckpoint("品种"+IntegerToString(i+1)+"发单前");
   string late=SendTimeRecheck(i,ev);
   if(late!="")
     {
      RecordEvent(i,ev,ST_MISSED,"发单前时间复核未通过，未下单",detail+" | 原因："+late);
      return;
     }

   // 6) 下单
   SendOrder(i,ev,detail,sl,tp);
  }

string PreTradeCheck(const int i,EventInfo &ev,const MqlTick &tk,const double sl,const double tp)
  {
   string sym=g_cfg[i].symbol;
   bool   isBuy=(g_cfg[i].dir==DIR_BUY);

   // 交易时段与交易权限
   long endSec=0;
   if(!FindTradeSession(sym,TimeTradeServer(),endSec))
      return "当前不在该品种的交易时段（市场关闭/休市）";
   long tm=SymbolInfoInteger(sym,SYMBOL_TRADE_MODE);
   if(tm==SYMBOL_TRADE_MODE_DISABLED)
      return "该品种当前禁止交易";
   if(tm==SYMBOL_TRADE_MODE_CLOSEONLY)
      return "该品种当前只允许平仓";
   if(isBuy && tm==SYMBOL_TRADE_MODE_SHORTONLY)
      return "该品种当前只允许卖出";
   if(!isBuy && tm==SYMBOL_TRADE_MODE_LONGONLY)
      return "该品种当前只允许买入";

   // 手数、价格精度（品种规则可能变化，下单前再查一次）
   string r=CheckLots(sym,g_cfg[i].effLots);
   if(r!="")
      return r;
   r=CheckPriceStep(sym,tp,"止盈价");
   if(r!="")
      return r;
   r=CheckPriceStep(sym,sl,"止损价");
   if(r!="")
      return r;

   // 止盈止损方向和最小距离（不自动修改价格，也不放大距离）
   r=CheckStopsVsTick(sym,isBuy,tk,sl,tp);
   if(r!="")
      return r;

   // 防重复 / 不干预其他仓位
   if(FindOwnPosition(sym)>0)
      return "该品种已有本EA持仓，按规则不加仓";
   if(IsNetting() && HasAnyPosition(sym))
      return "账户为净额模式，且该品种已有其他持仓（手动或其他EA），为避免影响这些仓位而跳过";
   if(HasOwnPendingOrder(sym))
      return "该品种有本EA尚未完成的订单";
   int dealState=OwnDealSince(sym,(datetime)((long)ev.checkUtc+g_serverOffsetSec-60));
   if(dealState<0)
      return "无法读取历史成交记录，为防止重复下单而跳过";
   if(dealState>0)
      return "检查时刻前后已有本EA在该品种的开仓成交，为防止重复而跳过";

   // 保证金
   ENUM_ORDER_TYPE ot=isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double margin=0.0;
   if(!OrderCalcMargin(ot,sym,g_cfg[i].effLots,isBuy ? tk.ask : tk.bid,margin))
      return "无法计算所需保证金";
   double freeMargin=AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(margin>freeMargin)
      return StringFormat("保证金不足：约需 %.2f，可用 %.2f %s",margin,freeMargin,AccountInfoString(ACCOUNT_CURRENCY));
   return "";
  }

string PermissionCheck()
  {
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
      return "MT5 工具栏的“算法交易”按钮未开启";
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
      return "本EA属性“常用”页未勾选“允许算法交易”";
   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
      return "当前账户不允许交易（可能用投资者只读密码登录）";
   if(!AccountInfoInteger(ACCOUNT_TRADE_EXPERT))
      return "券商不允许该账户使用EA交易";
   if(InpDemoOnly && AccountInfoInteger(ACCOUNT_TRADE_MODE)!=ACCOUNT_TRADE_MODE_DEMO)
      return "已开启“只允许在模拟账户下单”，当前不是模拟账户";
   return "";
  }

string ServerPreCheck(const int i,const MqlTick &tk,const double sl,const double tp)
  {
   string sym=g_cfg[i].symbol;
   bool   isBuy=(g_cfg[i].dir==DIR_BUY);
   MqlTradeRequest     rq={};
   MqlTradeCheckResult cr={};
   rq.action      =TRADE_ACTION_DEAL;
   rq.symbol      =sym;
   rq.volume      =g_cfg[i].effLots;
   rq.type        =isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   rq.price       =isBuy ? tk.ask : tk.bid;
   rq.sl          =sl;
   rq.tp          =tp;
   rq.deviation   =(ulong)InpDeviationPoints;
   rq.magic       =(ulong)InpMagic;
   rq.type_filling=GetFilling(sym);
   ResetLastError();
   bool ok=OrderCheck(rq,cr);
   if(!ok || (cr.retcode!=0 && cr.retcode!=TRADE_RETCODE_DONE))
      return StringFormat("下单前服务器预检未通过：返回码 %u，%s（错误码 %d）",cr.retcode,cr.comment,GetLastError());
   return "";
  }

// v1.19 发单前安全复核。返回空字符串表示全部通过（sl/tp 为本次实际发送的止盈止损，info 追加复核时的报价）；
// 否则返回未通过的原因，failState 为应记录的终态（价格条件不满足=ST_NOT_MET，其余=ST_SKIPPED）。
string FinalSendCheck(const int i,EventInfo &ev,double &sl,double &tp,string &info,int &failState)
  {
   failState=ST_SKIPPED;
   string sym=g_cfg[i].symbol;
   bool   isBuy=(g_cfg[i].dir==DIR_BUY);
   MqlTick nt;
   if(!SymbolInfoTick(sym,nt) || nt.bid<=0.0 || nt.ask<=0.0 || nt.ask<nt.bid)
      return "下单前取不到有效报价";
   if((long)TimeTradeServer()-(long)nt.time>InpMaxQuoteAgeSec)
      return "下单前最新报价已过期";
   double price=isBuy ? nt.ask : nt.bid;
   info+=" | 发单前复核报价 Bid="+P(sym,nt.bid)+" Ask="+P(sym,nt.ask)+"（"+SpreadDesc(i,nt)+"）";
   // 1) 价格条件（区间条件须上下限同时满足）
   if(!PriceCondMet(i,price))
     {
      failState=ST_NOT_MET;
      return "按最新报价复核，"+QuoteName(g_cfg[i].dir)+"="+P(sym,price)+" 已不满足价格条件（"+CondDesc(i)+"）";
     }
   // 2) 点差
   string r=SpreadCheck(i,nt);
   if(r!="")
      return r;
   // 3) 止盈止损：价格差/金额模式按最新报价重算（不放大距离、不裸单）；固定价格模式沿用设定值
   string mnote="";
   r=ComputeStops(i,nt,sl,tp,mnote);
   if(r!="")
      return r;
   if(sl<=0.0 || tp<=0.0)
      return "止盈或止损价格无效，禁止发送不带保护的订单";
   // 4) 交易时段、品种交易模式、手数、价格精度、止盈止损方向与最小距离、已有持仓/挂单/近期成交、保证金
   r=PreTradeCheck(i,ev,nt,sl,tp);
   if(r!="")
      return r;
   // 5) 交易权限
   r=PermissionCheck();
   if(r!="")
      return r;
   if(mnote!="")
      info+=" | 发单前"+mnote;
   info+=" | 本次发送 止盈="+P(sym,tp)+" 止损="+P(sym,sl);
   return "";
  }

// 发开仓单前的最终复核：返回空字符串表示可以发单；否则返回不能发单的原因
string SendTimeRecheck(const int i,EventInfo &ev)
  {
   if(g_st[i].armedKey!=ev.key)
      return "检查过程中检测到运行中断（处理或阻塞时间过长），就绪状态已取消";
   if(TerminalInfoInteger(TERMINAL_CONNECTED)==0)
      return "发单前终端与服务器断开连接";
   long now=(long)NowUtc();
   long chk=(long)ev.checkUtc;
   long windowEnd=chk+InpGraceSeconds;
   if(now<chk)
      return "当前时间早于检查时刻（系统时间可能被调整）";
   if(now>windowEnd)
      return "当前时间已超出检查窗口 "+IntegerToString(now-windowEnd)+" 秒（北京 "
             +FmtDT((datetime)(now+8*3600))+"，窗口截止 北京 "+FmtDT((datetime)(windowEnd+8*3600))+"）";
   return "";
  }

bool IsUncertainRetcode(const uint rc)
  {
   return (rc==0 || rc==TRADE_RETCODE_TIMEOUT || rc==TRADE_RETCODE_CONNECTION ||
           rc==TRADE_RETCODE_PLACED || rc==TRADE_RETCODE_ERROR);
  }

void SendOrder(const int i,EventInfo &ev,const string detail,const double sl,const double tp)
  {
   string sym=g_cfg[i].symbol;
   bool   isBuy=(g_cfg[i].dir==DIR_BUY);

   // 先写入“发送中”、调用强制保存并读回核对：终端在下单过程中崩溃后重启，只要该记录已保存，就不会对同一事件再次下单。
   // 记录没有建立成功时，禁止发送订单。
   if(!WriteEventState(ev.key,ST_SENDING))
     {
      BlockKey(ev.key,ST_RECORD_FAIL);
      g_st[i].lastResult=StateText(ST_RECORD_FAIL);
      Log(SlotTag(i)+" 【未下单】“发送中”记录未能建立，按规则禁止发送订单 | 事件 "+ev.key+" | "+detail);
      return;
     }

   g_trade.SetTypeFilling(GetFilling(sym));
   string cmt="SCE"+IntegerToString(i+1)+" "+DateKey(ev.localDate);

   // 发单前安全复核（v1.19，取代 v1.14 仅针对价格差模式的重算）：重新取最新报价，
   // 复核价格条件、点差、止盈止损、交易时段/模式、手数、已有持仓/挂单、保证金和交易权限。
   // 任何一项不通过：不下单，任务以终态结束（不删除记录、不重试、不补单）。
   double sendSl=sl,sendTp=tp;
   string info=detail;
   int    failState=ST_SKIPPED;
   string why=FinalSendCheck(i,ev,sendSl,sendTp,info,failState);
   if(why!="")
     {
      RecordEvent(i,ev,failState,(failState==ST_NOT_MET) ? "发单前复核：价格条件已不满足，未下单"
                                                         : "发单前安全复核未通过，未下单",
                  info+" | 原因："+why+" | 说明：订单未发出");
      return;
     }

   // 紧邻实际下单调用的最终复核（v1.13）：写入“发送中”记录及强制保存本身也可能阻塞，
   // 所以在记录建立成功、准备工作完成之后，再检查一次连续性，并用最新时间复核窗口、连接和就绪状态。
   // 复核失败：不下单，任务记为“已错过”并结束；不删除记录、不重新激活、不重试。
   // 若把状态从“发送中”改为“已错过”时写入失败，RecordEvent 会在本实例内封锁该任务，同样不下单。
   ContinuityCheckpoint("品种"+IntegerToString(i+1)+"下单调用前");
   string late=SendTimeRecheck(i,ev);
   if(late!="")
     {
      RecordEvent(i,ev,ST_MISSED,"下单调用前最终复核未通过，未下单",
                  info+" | 原因："+late
                  +" | 说明：订单未发出。若本次状态更新写入失败，全局变量中可能仍为“发送中”，但实际没有下单");
      return;
     }

   ResetLastError();
   bool ok=isBuy ? g_trade.Buy(g_cfg[i].effLots,sym,0.0,sendSl,sendTp,cmt)
                 : g_trade.Sell(g_cfg[i].effLots,sym,0.0,sendSl,sendTp,cmt);
   int  err=GetLastError();
   uint rc=g_trade.ResultRetcode();
   string res="返回码="+IntegerToString((long)rc)+"（"+g_trade.ResultRetcodeDescription()+"）"
              +" 订单号="+IntegerToString((long)g_trade.ResultOrder())
              +" 成交号="+IntegerToString((long)g_trade.ResultDeal())
              +" 成交价="+P(sym,g_trade.ResultPrice())
              +" 成交量="+NumStr(g_trade.ResultVolume())
              +" 错误码="+IntegerToString(err);

   if(rc==TRADE_RETCODE_DONE || rc==TRADE_RETCODE_DONE_PARTIAL)
     {
      RecordEvent(i,ev,ST_SENT_OK,(rc==TRADE_RETCODE_DONE_PARTIAL) ? "已部分成交" : "已成交",info+" | "+res);
      StartVerify(i,ev);
     }
   else
      if(IsUncertainRetcode(rc) || (ok && rc!=TRADE_RETCODE_DONE))
        {
         RecordEvent(i,ev,ST_UNCERTAIN,"下单结果不明确，不重试，正在核对",info+" | "+res);
         StartVerify(i,ev);
        }
      else
         RecordEvent(i,ev,ST_SEND_FAIL,"下单被拒绝/失败，本次不重试",info+" | "+res);
  }

//+------------------------------------------------------------------+
//| 下单后核对：确认持仓与止盈止损                                     |
//+------------------------------------------------------------------+
// 更新已记录事件的状态（只在核对阶段使用）
void SetEventState(const string key,const int state)
  {
   if(!WriteEventState(key,state))
      BlockKey(key,state);
  }

int EventState(const string key)
  {
   int bi=BlockedIndex(key);
   if(bi>=0)
      return g_blockedStates[bi];
   if(!GlobalVariableCheck(key))
      return 0;
   return (int)GlobalVariableGet(key);
  }

void StartVerify(const int i,EventInfo &ev)
  {
   g_st[i].verifyActive=true;
   g_st[i].verifyUntilUtc=(datetime)((long)NowUtc()+VERIFY_SECONDS);
   g_st[i].verifyFromServer=(datetime)((long)ev.checkUtc+g_serverOffsetSec-60);
   g_st[i].verifyKey=ev.key;
  }

void ProcessVerify(const int i,const datetime nowUtc)
  {
   if(!g_st[i].verifyActive)
      return;
   string sym=g_cfg[i].symbol;
   string tag=SlotTag(i);
   ulong pt=FindOwnPosition(sym);
   if(pt>0)
     {
      g_st[i].verifyActive=false;
      if(EventState(g_st[i].verifyKey)==ST_UNCERTAIN)
         SetEventState(g_st[i].verifyKey,ST_SENT_OK);
      Log(tag+" 核对：已找到本EA持仓 #"+IntegerToString((long)pt));
      int r=EnsureStops(i,pt);
      if(r!=0)
        {
         SetEventState(g_st[i].verifyKey,r);
         g_st[i].lastResult=StateText(r);
        }
      return;
     }
   if(OwnDealSince(sym,g_st[i].verifyFromServer)==1 && !HasOwnPendingOrder(sym))
     {
      g_st[i].verifyActive=false;
      if(EventState(g_st[i].verifyKey)==ST_UNCERTAIN)
         SetEventState(g_st[i].verifyKey,ST_SENT_OK);
      Log(tag+" 核对：找到本EA的开仓成交，但当前没有持仓（可能已触发止盈/止损或被平仓），请在“历史”中核对");
      return;
     }
   if((long)nowUtc>(long)g_st[i].verifyUntilUtc)
     {
      g_st[i].verifyActive=false;
      SetEventState(g_st[i].verifyKey,ST_MANUAL);   // 任务结束，不重发；标记为待人工核对
      g_st[i].lastResult=StateText(ST_MANUAL);
      string msg=" 核对：在 "+IntegerToString(VERIFY_SECONDS)
                 +" 秒内未发现本EA的持仓或成交。按规则不重试，请在“交易”和“历史”标签人工核对";
      if(HasOwnPendingOrder(sym))
         msg=" 核对：仍有本EA未完成的订单，按规则不重试，请人工核对";
      Log(tag+msg);
      Alert(tag+msg);
     }
  }

// 返回 0：止盈止损已确认（或补设成功）
//      ST_STOPS_INEXACT：价格差模式下已有保护，但未能按实际成交价精确调整（保留原保护，不平仓）
//      ST_STOPS_ISSUE：异常且仓位未确认关闭（需人工处理）
//      ST_CLOSE_PENDING：已发出平仓请求，正在核对（由 ProcessCloseVerify 给出最终结果）
int EnsureStops(const int i,const ulong ticket)
  {
   string sym=g_cfg[i].symbol;
   string tag=SlotTag(i);
   int    digits=(int)SymbolInfoInteger(sym,SYMBOL_DIGITS);
   double half=TickSize(sym)*0.5;
   double wantSl=NormalizeDouble(g_cfg[i].sl,digits);
   double wantTp=NormalizeDouble(g_cfg[i].tp,digits);

   if(!PositionSelectByTicket(ticket))
     {
      string m=" 警告：无法选中持仓 #"+IntegerToString((long)ticket)+"，无法确认止盈止损，请人工检查";
      Log(tag+m);
      Alert(tag+m);
      return ST_STOPS_ISSUE;
     }
   double origVol=PositionGetDouble(POSITION_VOLUME);
   long   posId=PositionGetInteger(POSITION_IDENTIFIER);
   double psl=PositionGetDouble(POSITION_SL);
   double ptp=PositionGetDouble(POSITION_TP);
   double openPrice=PositionGetDouble(POSITION_PRICE_OPEN);
   bool   isBuyPos=(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY);
   if(StopsByDist(i) && (EffTpDist(i)<=0.0 || EffSlDist(i)<=0.0))
     {
      // 防御：金额模式的换算距离只存在于本次运行内存。正常流程不会走到这里；若缺失则不改单，只按是否有双边保护下结论
      if(psl>0.0 && ptp>0.0)
        {
         string mm=" 警告：持仓 #"+IntegerToString((long)ticket)+" 的目标距离不可用，无法核对是否精确；当前已有双边保护 止损="
                   +P(sym,psl)+" 止盈="+P(sym,ptp)+"，不再改单，请人工核对";
         Log(tag+mm);
         Alert(tag+mm);
         return ST_STOPS_INEXACT;
        }
      return HandleNoProtection(i,ticket,posId,origVol," 持仓缺少止盈或止损，且目标距离不可用",g_st[i].verifyKey);
     }
   if(StopsByDist(i))
     {
      // 价格差/金额模式：目标价按“实际成交价 ± 距离”计算，并按最小价格变动取整
      wantTp=RoundToTick(sym,isBuyPos ? openPrice+EffTpDist(i) : openPrice-EffTpDist(i));
      wantSl=RoundToTick(sym,isBuyPos ? openPrice-EffSlDist(i) : openPrice+EffSlDist(i));
     }
   bool slOk=(psl>0.0 && MathAbs(psl-wantSl)<=half);
   bool tpOk=(ptp>0.0 && MathAbs(ptp-wantTp)<=half);
   if(slOk && tpOk)
     {
      Log(tag+" 已确认持仓 #"+IntegerToString((long)ticket)+" 止损="+P(sym,psl)+" 止盈="+P(sym,ptp)
          +(StopsByDist(i) ? "（与按实际成交价 "+P(sym,openPrice)+" 计算的目标一致）" : "")
          +MoneyAudit(i,isBuyPos,origVol,openPrice,psl,ptp));
      return 0;
     }

   // 价格差模式，且持仓已带止盈止损（下单时按预计开仓价设置）：只是因滑点/报价变化与实际成交价不完全对应。
   // 尝试按实际成交价调整一次；不合法或失败则保留原有保护，不平仓、不重试。
   if(StopsByDist(i) && psl>0.0 && ptp>0.0)
     {
      string base=" 持仓 #"+IntegerToString((long)ticket)+" 实际成交价 "+P(sym,openPrice)
                  +"，按距离计算的目标 止损="+P(sym,wantSl)+" 止盈="+P(sym,wantTp)
                  +"；当前持仓 止损="+P(sym,psl)+" 止盈="+P(sym,ptp)+"（差异来自滑点或报价变化）";
      string why="";
      MqlTick nt;
      if(!SymbolInfoTick(sym,nt) || nt.bid<=0.0 || nt.ask<=0.0)
         why="取不到最新报价，无法检查调整是否合法";
      else
        {
         why=CheckStopsVsTick(sym,isBuyPos,nt,wantSl,wantTp);
         if(why=="")
           {
            double point=SymbolInfoDouble(sym,SYMBOL_POINT);
            double fz=(double)SymbolInfoInteger(sym,SYMBOL_TRADE_FREEZE_LEVEL)*point;
            double cur=isBuyPos ? nt.bid : nt.ask;
            if(fz>0.0 && (MathAbs(cur-psl)<=fz || MathAbs(ptp-cur)<=fz))
               why="当前价格处于券商冻结距离内，不允许修改止盈止损";
           }
        }
      string note;
      if(why=="")
        {
         // 调整请求只提交这一次
         bool mod2=g_trade.PositionModify(ticket,wantSl,wantTp);
         uint rc2=g_trade.ResultRetcode();
         if(mod2 && rc2==TRADE_RETCODE_DONE && PositionSelectByTicket(ticket))
           {
            double nsl=PositionGetDouble(POSITION_SL);
            double ntp=PositionGetDouble(POSITION_TP);
            if(nsl>0.0 && ntp>0.0 && MathAbs(nsl-wantSl)<=half && MathAbs(ntp-wantTp)<=half)
              {
               Log(tag+base+"；已按实际成交价调整为 止损="+P(sym,nsl)+" 止盈="+P(sym,ntp)
                   +MoneyAudit(i,isBuyPos,origVol,openPrice,nsl,ntp));
               return 0;
              }
           }
         note=base+"；已提交一次调整，返回码 "+IntegerToString((long)rc2)+"（"+g_trade.ResultRetcodeDescription()
              +"），调用结果="+(mod2 ? "true" : "false")+"，结果需核对";
        }
      else
         note=base+"；未提交调整："+why;

      // 不再改单。进入有期限的只读核对：重新确认连接、目标持仓和实际 SL/TP 后才下结论
      g_st[i].stopsVerifyActive=true;
      g_st[i].stopsTicket=ticket;
      g_st[i].stopsPosId=posId;
      g_st[i].stopsWantSl=wantSl;
      g_st[i].stopsWantTp=wantTp;
      g_st[i].stopsUntilUtc=(datetime)((long)NowUtc()+STOPS_VERIFY_SECONDS);
      g_st[i].stopsKey=g_st[i].verifyKey;
      g_st[i].stopsNote=note;
      g_st[i].stopsLastWhy="";
      return StopsConfirmStep(i,NowUtc());
     }

   Log(tag+" 警告：持仓 #"+IntegerToString((long)ticket)+" 的止盈/止损与设定不一致（当前 止损="+P(sym,psl)
       +" 止盈="+P(sym,ptp)+"），尝试补设一次");
   bool mod=g_trade.PositionModify(ticket,wantSl,wantTp);
   uint rc=g_trade.ResultRetcode();
   if(mod && rc==TRADE_RETCODE_DONE && PositionSelectByTicket(ticket))
     {
      psl=PositionGetDouble(POSITION_SL);
      ptp=PositionGetDouble(POSITION_TP);
      if(psl>0.0 && ptp>0.0 && MathAbs(psl-wantSl)<=half && MathAbs(ptp-wantTp)<=half)
        {
         Log(tag+" 补设成功：止损="+P(sym,psl)+" 止盈="+P(sym,ptp)+MoneyAudit(i,isBuyPos,origVol,openPrice,psl,ptp));
         return 0;
        }
     }
   string msg=" 补设止盈止损失败（返回码 "+IntegerToString((long)rc)+" "+g_trade.ResultRetcodeDescription()+"）";
   return HandleNoProtection(i,ticket,posId,origVol,msg,g_st[i].verifyKey);
  }

// 保护异常处理（与 v1.14 及之前相同）：不自动平仓则报警；否则只提交一次平仓并进入平仓核对
int HandleNoProtection(const int i,const ulong ticket,const long posId,const double origVol,string msg,const string key)
  {
   string tag=SlotTag(i);
   if(!InpCloseIfNoStops)
     {
      msg+="；按设置不自动平仓，请立即人工处理！";
      Log(tag+msg);
      Alert(tag+msg);
      return ST_STOPS_ISSUE;
     }

   // 平仓只提交一次。成功与否不看 bool，而是看返回码，并在随后核对持仓是否真的消失。
   ResetLastError();
   bool sent=g_trade.PositionClose(ticket,(ulong)InpDeviationPoints);
   int  err=GetLastError();
   uint crc=g_trade.ResultRetcode();
   string cres="平仓请求返回码 "+IntegerToString((long)crc)+"（"+g_trade.ResultRetcodeDescription()+"）"
               +" 调用结果="+(sent ? "true" : "false")+" 错误码="+IntegerToString(err)
               +" 成交量="+NumStr(g_trade.ResultVolume());
   if(crc==TRADE_RETCODE_DONE || crc==TRADE_RETCODE_DONE_PARTIAL || IsUncertainRetcode(crc))
     {
      g_st[i].closeVerifyActive=true;
      g_st[i].closeTicket=ticket;
      g_st[i].closePosId=posId;
      g_st[i].closeOrderTicket=g_trade.ResultOrder();
      g_st[i].closeLastWhy="";
      g_st[i].closeOrigVol=origVol;
      g_st[i].closeUntilUtc=(datetime)((long)NowUtc()+CLOSE_VERIFY_SECONDS);
      g_st[i].closeKey=key;
      Log(tag+msg+"；已提交平仓请求（持仓 #"+IntegerToString((long)ticket)+" 标识 "+IntegerToString(posId)
          +"，原 "+NumStr(origVol)+" 手，平仓订单号 "+IntegerToString((long)g_trade.ResultOrder())+"）："+cres
          +"。正在核对仓位是否真正关闭，不会重复提交");
      return ST_CLOSE_PENDING;
     }
   msg+="；平仓请求被拒绝："+cres+"。仓位 #"+IntegerToString((long)ticket)
        +" 仍在且止盈止损不可靠，不会重复提交，请立即人工处理！";
   Log(tag+msg);
   Alert(tag+msg);
   return ST_STOPS_ISSUE;
  }

// 止盈止损只读核对的一步。不会提交任何改单请求。
// 返回：0=实际 SL/TP 与目标一致；ST_STOPS_INEXACT=确认有双边保护但距离不精确；
//       ST_CLOSE_PENDING / ST_STOPS_ISSUE=确认缺少保护后按既定规则处理的结果；
//       ST_CLOSED_OTHER=核对期间持仓已确认全部关闭；ST_STOPS_PENDING=仍在核对或核对超时（看 stopsVerifyActive）
int StopsConfirmStep(const int i,const datetime nowUtc)
  {
   string tag=SlotTag(i);
   string sym=g_cfg[i].symbol;
   ulong  t=g_st[i].stopsTicket;
   long   pid=g_st[i].stopsPosId;
   double half=TickSize(sym)*0.5;
   bool   connected=(TerminalInfoInteger(TERMINAL_CONNECTED)!=0);
   string why="";
   double vol=0.0;
   int    perr=0;

   if(!connected)
      why="终端未连接，无法确认实际止盈止损";
   else
     {
      int pres=PositionPresence(t,pid,vol,perr);
      if(pres<0)
         why="持仓查询异常（错误码 "+IntegerToString(perr)+"）";
      else
         if(pres==1)
           {
            // PositionPresence 找到持仓时，该持仓处于选中状态
            double psl=PositionGetDouble(POSITION_SL);
            double ptp=PositionGetDouble(POSITION_TP);
            double po =PositionGetDouble(POSITION_PRICE_OPEN);
            bool   buy=(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY);
            g_st[i].stopsVerifyActive=false;
            if(psl>0.0 && ptp>0.0)
              {
               if(MathAbs(psl-g_st[i].stopsWantSl)<=half && MathAbs(ptp-g_st[i].stopsWantTp)<=half)
                 {
                  Log(tag+g_st[i].stopsNote+"；核对确认：实际 止损="+P(sym,psl)+" 止盈="+P(sym,ptp)
                      +"，已与按实际成交价计算的目标一致（服务器已执行调整）"+MoneyAudit(i,buy,vol,po,psl,ptp));
                  return 0;
                 }
               double dsl=buy ? po-psl : psl-po;
               double dtp=buy ? ptp-po : po-ptp;
               string m=g_st[i].stopsNote+"；核对确认实际保护：成交价 "+P(sym,po)
                        +"，止损="+P(sym,psl)+"（距成交价 "+P(sym,dsl)+"），止盈="+P(sym,ptp)+"（距成交价 "+P(sym,dtp)+"）；"
                        +"目标距离 止损 "+NumStr(EffSlDist(i))+" 止盈 "+NumStr(EffTpDist(i))
                        +"。已有双边保护，但距离未精确调整；不再改单"+MoneyAudit(i,buy,vol,po,psl,ptp);
               Log(tag+m);
               Alert(tag+m);
               return ST_STOPS_INEXACT;
              }
            string miss=(psl<=0.0 && ptp<=0.0) ? "止损和止盈" : ((psl<=0.0) ? "止损" : "止盈");
            string m2=g_st[i].stopsNote+"；核对确认持仓 #"+IntegerToString((long)t)+" 缺少"+miss
                      +"（当前 止损="+P(sym,psl)+" 止盈="+P(sym,ptp)+"）。已提交过一次调整，不再改单，按保护异常规则处理";
            return HandleNoProtection(i,t,pid,vol,m2,g_st[i].stopsKey);
           }
         else
           {
            // 持仓列表中找不到：不直接当作已平仓，必须由成交历史确认
            bool ours=false;
            string detail="";
            int h=CloseHistory(pid,0,ours,detail);
            if(h==1)
              {
               g_st[i].stopsVerifyActive=false;
               string m3=g_st[i].stopsNote+"；核对期间持仓 #"+IntegerToString((long)t)
                         +" 已确认全部关闭（本EA未发出平仓请求，关闭来源以成交明细为准）。平仓明细："+detail;
               Log(tag+m3);
               Alert(tag+m3);
               return ST_CLOSED_OTHER;
              }
            why=(h<0) ? detail : "持仓列表中找不到，但"+detail;
           }
     }

   if(why!=g_st[i].stopsLastWhy)
     {
      g_st[i].stopsLastWhy=why;
      Log(tag+" 止盈止损只读核对中：持仓 #"+IntegerToString((long)t)+" "+why+"。不再改单，继续核对");
     }
   if((long)nowUtc<=(long)g_st[i].stopsUntilUtc)
      return ST_STOPS_PENDING;

   g_st[i].stopsVerifyActive=false;
   string m4=g_st[i].stopsNote+"；保护状态待核对：在 "+IntegerToString(STOPS_VERIFY_SECONDS)
             +" 秒内无法确认持仓 #"+IntegerToString((long)t)+" 的实际止盈止损（"+why
             +"）。不再改单，也不认定原保护仍然有效，请立即人工核对“交易”和“历史”标签！";
   Log(tag+m4);
   Alert(tag+m4);
   return ST_STOPS_PENDING;
  }

void ProcessStopsVerify(const int i,const datetime nowUtc)
  {
   if(!g_st[i].stopsVerifyActive)
      return;
   int r=StopsConfirmStep(i,nowUtc);
   if(g_st[i].stopsVerifyActive)
      return;   // 仍在核对
   int st=(r==0) ? ST_SENT_OK : r;
   SetEventState(g_st[i].stopsKey,st);
   g_st[i].lastResult=StateText(st);
  }

// 持仓是否仍存在：1=存在（vol 为剩余手数）；0=确认不在持仓列表；-1=查询异常（不能下结论）
int PositionPresence(const ulong ticket,const long posId,double &vol,int &err)
  {
   vol=0.0;
   err=0;
   bool anyErr=false;
   ResetLastError();
   int total=PositionsTotal();
   for(int k=0;k<total;k++)
     {
      ulong tk=PositionGetTicket(k);
      if(tk==0)
        {
         anyErr=true;
         err=GetLastError();
         continue;
        }
      if(tk==ticket || (posId!=0 && PositionGetInteger(POSITION_IDENTIFIER)==posId))
        {
         vol=PositionGetDouble(POSITION_VOLUME);
         return 1;
        }
     }
   ResetLastError();
   if(PositionSelectByTicket(ticket))
     {
      vol=PositionGetDouble(POSITION_VOLUME);
      return 1;
     }
   int e=GetLastError();
   if(anyErr)
      return -1;
   // 只有“未找到该持仓”这一种错误码（或无错误码）才视为不在持仓列表，其他错误一律视为查询异常
   if(e!=0 && e!=ERR_TRADE_POSITION_NOT_FOUND)
     {
      err=e;
      return -1;
     }
   return 0;
  }

string DealReasonText(const long r)
  {
   switch((int)r)
     {
      case DEAL_REASON_CLIENT: return "电脑端手动操作";
      case DEAL_REASON_MOBILE: return "手机端手动操作";
      case DEAL_REASON_WEB:    return "网页端手动操作";
      case DEAL_REASON_EXPERT: return "EA/脚本发出的订单";
      case DEAL_REASON_SL:     return "触发止损";
      case DEAL_REASON_TP:     return "触发止盈";
      case DEAL_REASON_SO:     return "强制平仓（保证金不足）";
      default:                 return "其他原因（代码 "+IntegerToString(r)+"）";
     }
  }

// 从成交历史核对该持仓是否已全部平仓：1=已全部平仓；0=历史尚不足以确认；-1=历史读取失败
// ours 返回：平仓成交中是否有一笔的订单号与本EA平仓请求返回的订单号一致
int CloseHistory(const long posId,const ulong closeOrder,bool &ours,string &detail)
  {
   ours=false;
   detail="";
   if(posId==0)
     {
      detail="缺少持仓标识，无法按持仓读取成交历史";
      return -1;
     }
   ResetLastError();
   if(!HistorySelectByPosition(posId))
     {
      detail="读取该持仓的成交历史失败（错误码 "+IntegerToString(GetLastError())+"）";
      return -1;
     }
   int n=HistoryDealsTotal();
   double inVol=0.0,outVol=0.0;
   bool inout=false;
   string closes="";
   for(int k=0;k<n;k++)
     {
      ulong d=HistoryDealGetTicket(k);
      if(d==0)
        {
         detail="读取成交记录失败（错误码 "+IntegerToString(GetLastError())+"）";
         return -1;
        }
      long   entry=HistoryDealGetInteger(d,DEAL_ENTRY);
      double v=HistoryDealGetDouble(d,DEAL_VOLUME);
      if(entry==DEAL_ENTRY_IN)
         inVol+=v;
      else
         if(entry==DEAL_ENTRY_OUT || entry==DEAL_ENTRY_OUT_BY)
           {
            outVol+=v;
            ulong ord=(ulong)HistoryDealGetInteger(d,DEAL_ORDER);
            if(closeOrder>0 && ord==closeOrder)
               ours=true;
            closes+=(closes=="" ? "" : "；")+"成交 #"+IntegerToString((long)d)+" 订单 #"+IntegerToString((long)ord)
                    +" "+NumStr(v)+" 手，原因："+DealReasonText(HistoryDealGetInteger(d,DEAL_REASON));
           }
         else
            if(entry==DEAL_ENTRY_INOUT)
               inout=true;
     }
   if(inout)
     {
      detail="成交历史中出现反手成交，无法自动判断";
      return 0;
     }
   if(inVol<=0.0)
     {
      detail="成交历史中尚无该持仓的开仓成交（可能未同步）";
      return 0;
     }
   if(outVol<inVol-1e-9)
     {
      detail="成交历史显示平仓 "+NumStr(outVol)+" 手 / 开仓 "+NumStr(inVol)+" 手，尚未全部平仓（或未同步）";
      return 0;
     }
   detail=closes;
   return 1;
  }

// 核对平仓结果。只有同时满足：终端已连接、持仓列表中确认没有该持仓、成交历史显示已全部平仓，
// 才算“已确认关闭”；关闭来源只有在平仓成交的订单号与本EA平仓请求一致时，才认定为本EA平仓。
// 无法确认时保持待核对，超时后报警，绝不重复提交平仓。
void ProcessCloseVerify(const int i,const datetime nowUtc)
  {
   if(!g_st[i].closeVerifyActive)
      return;
   string tag=SlotTag(i);
   ulong  t=g_st[i].closeTicket;
   long   pid=g_st[i].closePosId;
   string key=g_st[i].closeKey;
   string why="";
   double vol=0.0;
   int    perr=0;
   bool   connected=(TerminalInfoInteger(TERMINAL_CONNECTED)!=0);
   int    pres=PositionPresence(t,pid,vol,perr);

   if(!connected)
      why="终端未连接，持仓与成交数据可能未同步";
   else
      if(pres==1)
         why=(vol<g_st[i].closeOrigVol-1e-9) ? "持仓仍有剩余 "+NumStr(vol)+" 手（原 "+NumStr(g_st[i].closeOrigVol)+" 手）"
                                            : "持仓仍在（"+NumStr(vol)+" 手）";
      else
         if(pres<0)
            why="持仓查询异常（错误码 "+IntegerToString(perr)+"）";
         else
           {
            bool ours=false;
            string detail="";
            int h=CloseHistory(pid,g_st[i].closeOrderTicket,ours,detail);
            if(h==1)
              {
               g_st[i].closeVerifyActive=false;
               int st=ours ? ST_CLOSED_NO_STOPS : ST_CLOSED_OTHER;
               SetEventState(key,st);
               g_st[i].lastResult=StateText(st);
               string m=" 已确认持仓 #"+IntegerToString((long)t)+" 已全部关闭（持仓列表无此仓位，且成交历史平仓量等于开仓量）。"
                        +(ours ? "平仓成交的订单号与本EA平仓请求一致（订单 #"+IntegerToString((long)g_st[i].closeOrderTicket)+"）。"
                               : "平仓成交与本EA平仓请求的订单号"+((g_st[i].closeOrderTicket>0) ? "（#"+IntegerToString((long)g_st[i].closeOrderTicket)+"）" : "（本EA请求未返回订单号）")
                                 +"不能对应，不认定为本EA平仓。")
                        +"平仓成交明细："+detail;
               Log(tag+m);
               Alert(tag+m);
               return;
              }
            why=(h<0) ? detail : "持仓列表中已找不到，但"+detail;
           }

   if(why!=g_st[i].closeLastWhy)
     {
      g_st[i].closeLastWhy=why;
      Log(tag+" 平仓核对中：持仓 #"+IntegerToString((long)t)+" "+why+"。继续核对，不重复提交平仓");
     }
   if((long)nowUtc<=(long)g_st[i].closeUntilUtc)
      return;

   // 超时：按最后掌握的证据给出结论，均需人工处理
   g_st[i].closeVerifyActive=false;
   string m;
   int st;
   if(connected && pres==1)
     {
      st=ST_STOPS_ISSUE;
      m=(vol<g_st[i].closeOrigVol-1e-9)
        ? " 平仓只部分完成：持仓 #"+IntegerToString((long)t)+" 剩余 "+NumStr(vol)+" 手（原 "+NumStr(g_st[i].closeOrigVol)+" 手），剩余仓位止盈止损不可靠"
        : " 平仓未完成：发出平仓请求 "+IntegerToString(CLOSE_VERIFY_SECONDS)+" 秒后持仓 #"+IntegerToString((long)t)+" 仍在（"+NumStr(vol)+" 手）";
     }
   else
     {
      st=ST_CLOSE_PENDING;
      m=" 平仓结果无法确认："+why;
     }
   m+="。不会重复提交平仓，请立即人工核对“交易”和“历史”标签！";
   SetEventState(key,st);
   g_st[i].lastResult=StateText(st);
   Log(tag+m);
   Alert(tag+m);
  }

//+------------------------------------------------------------------+
//| 启动时检查遗留状态                                                 |
//+------------------------------------------------------------------+
void StartupAudit()
  {
   for(int k=PositionsTotal()-1;k>=0;k--)
     {
      ulong t=PositionGetTicket(k);
      if(t==0 || PositionGetInteger(POSITION_MAGIC)!=InpMagic)
         continue;
      string sym=PositionGetString(POSITION_SYMBOL);
      double psl=PositionGetDouble(POSITION_SL);
      double ptp=PositionGetDouble(POSITION_TP);
      if(psl<=0.0 || ptp<=0.0)
        {
         string msg="警告：发现本EA持仓 #"+IntegerToString((long)t)+" ["+sym+"] 缺少止盈或止损，请人工检查（启动时不自动处理）";
         Log(msg);
         Alert(msg);
        }
      else
         Log("启动检查：本EA现有持仓 #"+IntegerToString((long)t)+" ["+sym+"] 止损="+P(sym,psl)+" 止盈="+P(sym,ptp));
     }
   string prefix=GV_PREFIX+IntegerToString(InpMagic)+"_";
   int total=GlobalVariablesTotal();
   for(int k=0;k<total;k++)
     {
      string n=GlobalVariableName(k);
      if(StringFind(n,prefix)!=0)
         continue;
      int v=(int)GlobalVariableGet(n);
      if(v==ST_SENDING || v==ST_UNCERTAIN || v==ST_MANUAL || v==ST_STOPS_ISSUE || v==ST_CLOSE_PENDING || v==ST_STOPS_PENDING)
         Log("提示：事件 "+n+" 状态为“"+StateText(v)+"”，本EA不会对该事件再次下单，请人工核对");
     }
  }

//+------------------------------------------------------------------+
//| 单实例保护（同一 Magic 只允许一个图表运行）                        |
//+------------------------------------------------------------------+
bool AcquireLock()
  {
   g_lockName="SCELOCK_"+IntegerToString(InpMagic);
   g_hbName  ="SCEHB_"+IntegerToString(InpMagic);
   if(GlobalVariableCheck(g_lockName))
     {
      double hb=GlobalVariableCheck(g_hbName) ? GlobalVariableGet(g_hbName) : 0.0;
      if((double)TimeLocal()-hb<15.0)
         return false;
     }
   g_instanceId=(double)(GetMicrosecondCount()%1000000000)+1.0;
   GlobalVariableTemp(g_lockName);
   datetime r1=GlobalVariableSet(g_lockName,g_instanceId);
   GlobalVariableTemp(g_hbName);
   datetime r2=GlobalVariableSet(g_hbName,(double)TimeLocal());
   if(r1==0 || r2==0 || !GlobalVariableCheck(g_lockName) || GlobalVariableGet(g_lockName)!=g_instanceId)
     {
      g_lockError="无法建立单实例锁（全局变量写入失败，错误码 "+IntegerToString(GetLastError())+"）";
      return false;
     }
   g_lockHeld=true;
   return true;
  }

void ReleaseLock()
  {
   if(!g_lockHeld)
      return;
   if(GlobalVariableCheck(g_lockName) && GlobalVariableGet(g_lockName)==g_instanceId)
     {
      GlobalVariableDel(g_lockName);
      GlobalVariableDel(g_hbName);
     }
   g_lockHeld=false;
  }

//+------------------------------------------------------------------+
//| 图表显示                                                          |
//+------------------------------------------------------------------+
// v1.17：面板用 OBJ_LABEL 文本对象显示，字号 12，从图表左上角起一行一个逻辑行。
// v1.18：每组任务分两行（UpdateDisplay 组装）；任何一行宽于 1500 像素时在“ | ”处兜底折行（DrawPanel / PanelWrap）。
// 单个文本对象能显示的字符数有限（63 个），所以一行按 60 个字符切成若干段，按实测像素宽度从左到右紧接排列。
// 对象只在首次出现时创建，之后只在文字/位置/颜色变化时修改属性，并且只在有变化时重绘一次图表，不删除重建，避免闪烁。
string PanelPrefix()
  {
   return "SCEPNL_"+IntegerToString(InpMagic)+"_";
  }

// 创建或更新一个文本对象；返回是否有任何改动
bool PanelSetLabel(const string name,const int x,const int y,const string text,
                   const string font,const int size,const color clr)
  {
   bool changed=false;
   if(ObjectFind(0,name)<0)
     {
      if(!ObjectCreate(0,name,OBJ_LABEL,0,0,0))
         return false;
      ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
      ObjectSetInteger(0,name,OBJPROP_ANCHOR,ANCHOR_LEFT_UPPER);
      ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
      ObjectSetInteger(0,name,OBJPROP_BACK,false);
      ObjectSetString(0,name,OBJPROP_FONT,font);
      ObjectSetInteger(0,name,OBJPROP_FONTSIZE,size);
      changed=true;
     }
   if(ObjectGetInteger(0,name,OBJPROP_XDISTANCE)!=x)
     {
      ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
      changed=true;
     }
   if(ObjectGetInteger(0,name,OBJPROP_YDISTANCE)!=y)
     {
      ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
      changed=true;
     }
   if((color)ObjectGetInteger(0,name,OBJPROP_COLOR)!=clr)
     {
      ObjectSetInteger(0,name,OBJPROP_COLOR,clr);
      changed=true;
     }
   if(ObjectGetString(0,name,OBJPROP_TEXT)!=text)
     {
      ObjectSetString(0,name,OBJPROP_TEXT,text);
      changed=true;
     }
   return changed;
  }

// 按当前 TextSetFont 设置测量文字宽度（像素）；测量失败时按每字 16 像素从宽估计
int PanelTextWidth(const string s)
  {
   uint tw=0,th=0;
   if(TextGetSize(s,tw,th) && tw>0)
      return (int)tw;
   return StringLen(s)*16;
  }

// v1.18 兜底折行：一行宽于 maxW 像素时，在“ | ”分隔处折到下一行（续行缩进 4 个空格，折行处的“ | ”省去）；
// 单个字段本身就宽于 maxW 时按字符切开。正常情况下各行都不超宽，不会触发。返回物理行数。
int PanelWrap(const string line,const int maxW,string &out[])
  {
   ArrayResize(out,0);
   string rest=line;
   bool   first=true;
   for(int guard=0;guard<50;guard++)
     {
      string cur=first ? rest : "    "+rest;
      int    n=ArraySize(out);
      if(PanelTextWidth(cur)<=maxW)
        {
         ArrayResize(out,n+1);
         out[n]=cur;
         break;
        }
      int cut=-1;
      int q=StringFind(cur," | ");
      while(q>0 && PanelTextWidth(StringSubstr(cur,0,q))<=maxW)
        {
         cut=q;
         q=StringFind(cur," | ",q+3);
        }
      int take=cut;
      int skip=3;
      if(cut<=0)
        {
         // 没有能放下的分隔处：二分找能放下的最长前缀，按字符切开
         int lo=1,hi=StringLen(cur);
         while(lo<hi)
           {
            int mid=(lo+hi+1)/2;
            if(PanelTextWidth(StringSubstr(cur,0,mid))<=maxW)
               lo=mid;
            else
               hi=mid-1;
           }
         take=lo;
         skip=0;
        }
      ArrayResize(out,n+1);
      out[n]=StringSubstr(cur,0,take);
      rest=StringSubstr(cur,take+skip);
      first=false;
     }
   return ArraySize(out);
  }

// 把面板文字（以 \n 分逻辑行）画成文本对象；超过 maxW 像素的逻辑行按 PanelWrap 折行
void DrawPanel(const string text)
  {
   const string font="Microsoft YaHei";
   const int    size=12;
   const int    segChars=60;
   const int    maxW=1500;
   string pre=PanelPrefix();
   color  clr=(color)ChartGetInteger(0,CHART_COLOR_FOREGROUND);
   string logical[];
   int    nLogical=StringSplit(text,'\n',logical);
   uint   tw=0,th=0;
   TextSetFont(font,-size*10);   // 负值 = 以 0.1 点为单位，与对象的字号 12（点）一致，用于测量段宽
   int    lineH=(TextGetSize("国",tw,th) && th>0) ? (int)th+4 : 22;
   string rows[];
   int    nRows=0;
   for(int k=0;k<nLogical;k++)
     {
      string parts[];
      int    np=PanelWrap(logical[k],maxW,parts);
      ArrayResize(rows,nRows+np);
      for(int j=0;j<np;j++)
         rows[nRows+j]=parts[j];
      nRows+=np;
     }
   bool   changed=false;
   int    r=0;
   for(r=0;r<nRows;r++)
     {
      string line=(rows[r]=="") ? " " : rows[r];   // 空文字的标签会显示默认的“Label”，用空格代替
      int    len=StringLen(line);
      int    x=10;
      int    seg=0;
      for(int p=0;p<len;p+=segChars)
        {
         string part=StringSubstr(line,p,segChars);
         if(PanelSetLabel(pre+IntegerToString(r)+"_"+IntegerToString(seg),x,10+r*lineH,part,font,size,clr))
            changed=true;
         x+=(TextGetSize(part,tw,th) && tw>0) ? (int)tw : segChars*size;
         seg++;
        }
      // 本行变短时，删除多出来的旧段
      while(ObjectFind(0,pre+IntegerToString(r)+"_"+IntegerToString(seg))>=0)
        {
         ObjectDelete(0,pre+IntegerToString(r)+"_"+IntegerToString(seg));
         seg++;
         changed=true;
        }
     }
   // 行数变少时，删除多出来的旧行
   while(ObjectFind(0,pre+IntegerToString(r)+"_0")>=0)
     {
      ObjectsDeleteAll(0,pre+IntegerToString(r)+"_");
      r++;
      changed=true;
     }
   if(changed)
      ChartRedraw(0);
  }

void UpdateDisplay(const datetime nowUtc,const bool connected)
  {
   bool demo=(AccountInfoInteger(ACCOUNT_TRADE_MODE)==ACCOUNT_TRADE_MODE_DEMO);
   string s="【收盘前检查开仓EA】 模式："+((InpRunMode==RUN_TRADE) ? "允许交易" : "仅记录信号（不下单）");
   if(InpRunMode==RUN_TRADE)
      s+=InpDemoOnly ? "（仅限模拟账户）" : "（模拟/真实账户均可下单）";
   s+="\n账户："+(demo ? "模拟" : "真实")+" | "+(IsNetting() ? "净额模式" : "对冲模式")
      +" | Magic="+IntegerToString(InpMagic)+" | 连接："+(connected ? "正常" : "断开");
   s+="\n当前 北京 "+FmtDT((datetime)((long)nowUtc+8*3600))+" | 服务器 "+FmtDT(TimeTradeServer())
      +" | 服务器=UTC"+OffsetText(g_serverOffsetSec)+((InpServerTzMode==SERVER_TZ_AUTO) ? "（自动）" : "（手动）");
   s+="\n运行连续性：已连续运行 "+DurText((g_runStartUtc==0) ? 0 : (long)nowUtc-(long)g_runStartUtc)
      +"（就绪需≥"+IntegerToString(MIN_CONTINUOUS_SECONDS)+"秒）| 允许停顿 ≤"+IntegerToString(InpMaxTimerGapSec)+" 秒"
      +((g_lastGapInfo!="") ? " | 最近一次："+g_lastGapInfo : " | 本次加载以来未检测到中断");
   if(g_chartNote!="")
      s+="\n"+g_chartNote;
   for(int i=0;i<SLOT_COUNT;i++)
     {
      s+="\n["+IntegerToString(i+1)+"] ";
      if(!g_cfg[i].enabled)
        {
         s+="未启用";
         continue;
        }
      if(!g_cfg[i].valid)
        {
         s+="["+g_cfg[i].symbol+"] 参数无效，不会检查/下单："+g_cfg[i].invalidReason;
         continue;
        }
      // v1.18：每组两行。第一行：品种 方向 手数 | 执行方式 | 目标收盘 | 检查时刻；
      //        第二行（缩进）：开仓条件 | 止盈止损 | 时段结论 | 状态（按星期重复另有“上次”）。字段与 v1.17 单行完全相同，只是分到两行。
      string sym=g_cfg[i].symbol;
      string rowA=sym+" "+DirText(g_cfg[i].dir)+" "+LotsDesc(i);
      string rowB="\n    "+CondDesc(i)+" | "+StopsDesc(i)
                  +((g_cfg[i].maxSpread>0.0) ? " | 点差上限 "+NumStr(g_cfg[i].maxSpread) : "");
      EventInfo ev;
      bool   hasEv=false;
      if(g_cfg[i].execMode==EXEC_ONCE)
        {
         GetOnceEvent(i,ev);
         hasEv=true;
         rowA+=" | 一次性 | ";
        }
      else
        {
         rowA+=" | 按星期重复（"+WeekdaysText(i)+"）";
         if(FindNextEvent(i,nowUtc,ev))
           {
            hasEv=true;
            rowA+=" | 下次 ";
           }
         else
            rowA+=" | 未来8天内没有执行日";
        }
      if(hasEv)
        {
         // ScheduleText = 目标收盘 … | 检查 北京 … / 服务器≈ …（提前N分钟） | 时段结论。
         // 最后一个“ | ”之前（目标收盘、检查时刻）放第一行，之后（时段结论）放第二行。
         string sch=ScheduleText(i,ev);
         int    cut=-1;
         int    q=StringFind(sch," | ");
         while(q>=0)
           {
            cut=q;
            q=StringFind(sch," | ",q+3);
           }
         if(cut>0)
           {
            rowA+=StringSubstr(sch,0,cut);
            rowB+=" | "+StringSubstr(sch,cut+3);
           }
         else
            rowA+=sch;
         rowB+=" | 状态："+EventStatusText(i,ev,nowUtc);
        }
      if(g_cfg[i].execMode!=EXEC_ONCE && g_st[i].lastResult!="")
         rowB+=" | 上次："+g_st[i].lastResult;
      // v1.19：第三行显示本实例内最近一次结果（检查报价、点差、未执行原因）；重新加载后此行消失，以日志为准
      if(g_st[i].lastInfo!="" && (g_cfg[i].execMode!=EXEC_ONCE || (hasEv && g_st[i].lastInfoKey==ev.key)))
         rowB+="\n    本次结果："+g_st[i].lastInfo;
      s+=rowA+rowB;
     }
   DrawPanel(s);
  }

//+------------------------------------------------------------------+
//| EA 入口                                                           |
//+------------------------------------------------------------------+
int OnInit()
  {
   // 注意：修改参数或切换图表周期时，MT5 不会重新初始化全局变量，所以这里全部手动重置
   g_offsetInit=false;
   g_offsetOk=false;
   g_serverOffsetSec=0;
   g_lockHeld=false;
   g_lastConnected=(TerminalInfoInteger(TERMINAL_CONNECTED)!=0);
   g_logFile=InpWriteLogFile ? "SessionCloseEntry_"+IntegerToString(InpMagic)+".log" : "";
   for(int i=0;i<SLOT_COUNT;i++)
     {
      g_st[i].armedKey="";
      g_st[i].retryReason="";
      g_st[i].retryLoggedKey="";
      g_st[i].lastResult="";
      g_st[i].lastInfo="";
      g_st[i].lastInfoKey="";
      g_st[i].scheduleKey="";
      g_st[i].verifyActive=false;
      g_st[i].verifyUntilUtc=0;
      g_st[i].verifyFromServer=0;
      g_st[i].verifyKey="";
      g_st[i].stopsVerifyActive=false;
      g_st[i].stopsTicket=0;
      g_st[i].stopsPosId=0;
      g_st[i].stopsWantSl=0.0;
      g_st[i].stopsWantTp=0.0;
      g_st[i].stopsUntilUtc=0;
      g_st[i].stopsKey="";
      g_st[i].stopsNote="";
      g_st[i].stopsLastWhy="";
      g_st[i].closeVerifyActive=false;
      g_st[i].closeTicket=0;
      g_st[i].closePosId=0;
      g_st[i].closeOrderTicket=0;
      g_st[i].closeLastWhy="";
      g_st[i].closeOrigVol=0.0;
      g_st[i].closeUntilUtc=0;
      g_st[i].closeKey="";
     }
   // 运行连续性：重新加载后从零开始（就绪状态也已清空，检查时刻前必须重新连续运行）
   g_lastCkptUtc=0;
   g_lastCkptMs=0;
   g_lastGapInfo="";
   g_runStartUtc=0;
   // 注意：g_blockedKeys 不在这里清空。修改参数等重新初始化时，本程序内已封锁的任务继续保持封锁。

   string g=ValidateGlobals();
   if(g!="")
     {
      Alert("收盘前检查开仓EA 参数错误："+g);
      Print("收盘前检查开仓EA 参数错误："+g);
      return INIT_PARAMETERS_INCORRECT;
     }

   g_lockError="";
   if(!AcquireLock())
     {
      string m=(g_lockError!="") ? g_lockError+"。为防止重复下单，本次加载被拒绝。"
               : "已有另一个使用相同 Magic Number（"+IntegerToString(InpMagic)+"）的本EA在运行。为防止重复下单，本次加载被拒绝。";
      Alert(m);
      Print(m);
      return INIT_FAILED;
     }

   UpdateServerOffset();

   g_trade.SetExpertMagicNumber((ulong)InpMagic);
   g_trade.SetDeviationInPoints((ulong)InpDeviationPoints);
   g_trade.SetAsyncMode(false);
   g_trade.SetMarginMode();
   g_trade.LogLevel(LOG_LEVEL_ERRORS);

   bool demo=(AccountInfoInteger(ACCOUNT_TRADE_MODE)==ACCOUNT_TRADE_MODE_DEMO);
   Log("========== EA 启动（v1.19） ==========");
   Log("运行模式："+((InpRunMode==RUN_TRADE) ? "允许交易" : "仅记录信号（不下单）")
       +" | 只限模拟账户："+(InpDemoOnly ? "是" : "否")
       +" | 当前账户："+(demo ? "模拟" : "真实")+" "+IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN))
       +" | "+(IsNetting() ? "净额模式" : "对冲模式")
       +" | Magic="+IntegerToString(InpMagic)
       +" | 容错窗口="+IntegerToString(InpGraceSeconds)+"秒 | 报价过期="+IntegerToString(InpMaxQuoteAgeSec)+"秒");
   Log("报价规则：买入用 Ask 判断条件，卖出用 Bid 判断条件；下单为市价单，阈值/区间只是触发条件，不保证成交价。"
       +"发单前会按最新报价再复核一次价格条件、点差、止盈止损、权限和已有持仓，任何一项不通过都不下单。");

   LoadAllSlots();
   int enabledCount=0;
   for(int i=0;i<SLOT_COUNT;i++)
     {
      if(!g_cfg[i].enabled)
         continue;
      enabledCount++;
      string r=CheckSlotParams(i);
      if(r!="")
        {
         g_cfg[i].valid=false;
         g_cfg[i].invalidReason=r;
         Log(SlotTag(i)+" 参数无效，此品种不会检查或下单："+r);
         continue;
        }
      g_cfg[i].valid=true;
      string sym=g_cfg[i].symbol;
      string modeText=(g_cfg[i].execMode==EXEC_ONCE)
                      ? "一次性：目标收盘 "+TimeToString(g_cfg[i].closeDate,TIME_DATE)+" "+g_cfg[i].closeTimeText
                      : "按星期重复："+WeekdaysText(i)+" "+g_cfg[i].closeTimeText;
      Log(SlotTag(i)+" 已启用："+modeText+"（"+TzName(i)+"）提前 "
          +IntegerToString(g_cfg[i].leadMinutes)+" 分钟检查"
          +" | 条件："+CondDesc(i)
          +" | "+DirText(g_cfg[i].dir)+" "+LotsDesc(i)+" | "+StopsDesc(i));
      LogSlotWarnings(i);
     }
   if(enabledCount==0)
      Log("当前没有启用任何品种（所有品种默认关闭）。");

   // v1.19：图表品种与任务品种不一致时给出提示（仅提示；本EA由每秒定时器驱动，不依赖图表品种的报价）
   g_chartNote="";
   bool anyValid=false,chartMatch=false;
   string others="";
   for(int i=0;i<SLOT_COUNT;i++)
     {
      if(!g_cfg[i].enabled || !g_cfg[i].valid)
         continue;
      anyValid=true;
      if(g_cfg[i].symbol==_Symbol)
         chartMatch=true;
      else
         if(StringFind(others,"["+g_cfg[i].symbol+"]")<0)
            others+="["+g_cfg[i].symbol+"]";
     }
   if(anyValid && others!="")
     {
      g_chartNote="提示：本图表品种为 ["+_Symbol+"]，任务品种含 "+others+"。触发由每秒定时器驱动、报价按任务品种读取，不受图表品种影响；看图时请注意区分";
      Log(g_chartNote+(chartMatch ? "" : "（本图表品种不在已启用任务中）"));
     }

   StartupAudit();

   if(!EventSetTimer(1))
     {
      Alert("无法启动定时器，EA 停止");
      ReleaseLock();
      return INIT_FAILED;
     }
   OnTimer();   // 立即刷新一次显示和计划
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   Comment("");
   ObjectsDeleteAll(0,PanelPrefix());   // v1.17：删除本EA的面板文本对象
   ChartRedraw(0);
   ReleaseLock();
   Log("EA 已停止（原因代码 "+IntegerToString(reason)+"）");
  }

void OnTimer()
  {
   ContinuityCheckpoint("定时器开始");
   UpdateServerOffset();
   if(g_lockHeld)
      GlobalVariableSet(g_hbName,(double)TimeLocal());   // 心跳，用于单实例保护

   bool connectedNow=(TerminalInfoInteger(TERMINAL_CONNECTED)!=0);
   if(connectedNow!=g_lastConnected)
     {
      Log(connectedNow ? "终端已重新连接到交易服务器" : "终端与交易服务器断开连接");
      g_lastConnected=connectedNow;
     }

   for(int i=0;i<SLOT_COUNT;i++)
     {
      if(!g_cfg[i].enabled || !g_cfg[i].valid)
         continue;
      // 每组处理前：检查连续性（覆盖上一组的处理耗时），并重新取得当前时间和连接状态
      ContinuityCheckpoint("处理品种"+IntegerToString(i+1)+"前");
      datetime nowUtc=NowUtc();
      bool connected=(TerminalInfoInteger(TERMINAL_CONNECTED)!=0);
      ProcessSlot(i,nowUtc,connected);
      // 核对（下单结果、止盈止损、平仓）不受检查窗口限制，使用最新时间继续进行
      nowUtc=NowUtc();
      ProcessVerify(i,nowUtc);
      ProcessCloseVerify(i,NowUtc());
      ProcessStopsVerify(i,NowUtc());
      LogScheduleIfChanged(i,NowUtc());
     }
   UpdateDisplay(NowUtc(),(TerminalInfoInteger(TERMINAL_CONNECTED)!=0));
   ContinuityCheckpoint("定时器结束");
  }

// 运行连续性检查点。在定时器开始、每组处理前、发开仓单前、定时器结束时调用。
// 与上一个检查点之间的间隔（无论是两次回调之间的空闲，还是本EA回调内部的处理/阻塞）
// 超过 InpMaxTimerGapSec，或系统时间倒退，都视为“运行中断”：取消所有就绪状态，连续运行重新计时。
// 这只影响新的开仓检查；下单结果、止盈止损、平仓的核对不受影响。
void ContinuityCheckpoint(const string where)
  {
   datetime nowUtc=NowUtc();
   ulong    nowMs=GetTickCount64();
   if(g_lastCkptMs==0)
      g_runStartUtc=nowUtc;   // 本次加载后的第一个检查点：开始计算连续运行时间
   else
     {
      long wallGap=(long)nowUtc-(long)g_lastCkptUtc;
      long monoGapMs=(long)(nowMs-g_lastCkptMs);
      if(wallGap<0 || wallGap>InpMaxTimerGapSec || monoGapMs>(long)InpMaxTimerGapSec*1000)
         HandleDiscontinuity(nowUtc,wallGap,monoGapMs,where);
     }
   g_lastCkptUtc=nowUtc;
   g_lastCkptMs=nowMs;
  }

void HandleDiscontinuity(const datetime nowUtc,const long wallGap,const long monoGapMs,const string where)
  {
   g_runStartUtc=nowUtc;      // 连续运行从现在重新计算
   string cancelled="";
   for(int i=0;i<SLOT_COUNT;i++)
      if(g_st[i].armedKey!="")
        {
         cancelled+=(cancelled=="" ? "" : "、")+"品种"+IntegerToString(i+1);
         g_st[i].armedKey="";
        }
   g_lastGapInfo="北京 "+FmtDTm((datetime)((long)nowUtc+8*3600))+" "+where+" 检测到中断（系统时间差 "
                 +IntegerToString(wallGap)+" 秒，单调计时 "+DoubleToString(monoGapMs/1000.0,1)+" 秒）";
  Log("检测到运行中断（位置："+where+"）：距上一个检查点，系统时间差 "+IntegerToString(wallGap)+" 秒、单调计时 "
       +DoubleToString(monoGapMs/1000.0,1)+" 秒，超过允许的 "+IntegerToString(InpMaxTimerGapSec)
       +" 秒（或系统时间倒退）。可能原因：电脑休眠、终端或本EA处理阻塞（如同步下单耗时过长）、系统时间调整。"
       +((cancelled!="") ? "已取消 "+cancelled+" 的就绪状态，相关检查将按“已错过”处理，不补单；已有订单/持仓的核对照常进行。"
                         : "当前没有处于就绪状态的检查。"));
  }

void OnTick()
  {
   // 不依赖行情跳动，所有逻辑在 OnTimer 中执行
  }
//+------------------------------------------------------------------+

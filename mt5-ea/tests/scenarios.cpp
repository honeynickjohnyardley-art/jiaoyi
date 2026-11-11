// SessionCloseEntry 模拟测试：同一套场景分别编译进 v1.18 与 v1.19，
//   R 开头 = 旧功能回归（两版输出的“结果指纹”必须逐字相同）；
//   N 开头 = v1.19 新功能（只在 v1.19 中运行，带断言）。
// 编译：g++ -std=c++17 -I. -DEA='"build/ea_v119.cpp"' -DV119 scenarios.cpp
#include EA
#include <iostream>
#include <sstream>

Sim SIMG;
static int g_fail=0,g_pass=0;
static const char *NAS="纳斯达克100";
static const char *XAU="XAUUSD";
static const char *A50="中国A50指数 Micro";
static const char *ODD="ODDFX";

#define SETSLOT(N) \
static void slot##N(bool en,int em,const char *sym,const char *date,const char *tm,int lead,int cond,double thr,int dir, \
                    int lotMode,double lots,int sm,double tp,double sl,double tpd,double sld) \
  { S##N##_Enabled=en; S##N##_ExecMode=(ENUM_EXEC_MODE)em; S##N##_Symbol=string(sym); S##N##_CloseDate=string(date); \
    S##N##_CloseTime=string(tm); S##N##_TimeZone=TZ_SERVER; S##N##_LeadMinutes=lead; S##N##_Condition=(ENUM_COND)cond; \
    S##N##_Threshold=thr; S##N##_Direction=(ENUM_DIR)dir; S##N##_LotMode=(ENUM_LOT_MODE)lotMode; S##N##_Lots=lots; \
    S##N##_StopsMode=(ENUM_STOPS_MODE)sm; S##N##_TakeProfit=tp; S##N##_StopLoss=sl; S##N##_TPDistance=tpd; S##N##_SLDistance=sld; }
SETSLOT(1) SETSLOT(2) SETSLOT(3)

static void clearInputs()
  {
   InpRunMode=RUN_TRADE; InpDemoOnly=true; InpMagic=26109901; InpGraceSeconds=60; InpMaxTimerGapSec=10; InpMaxQuoteAgeSec=30;
   InpDeviationPoints=20; InpCloseIfNoStops=true; InpServerTzMode=SERVER_TZ_AUTO; InpWriteLogFile=false;
   slot1(false,0,"","","",5,0,0,0,0,0,0,0,0,0,0);
   slot2(false,0,"","","",5,0,0,0,0,0,0,0,0,0,0);
   slot3(false,0,"","","",5,0,0,0,0,0,0,0,0,0,0);
   S1_Mon=S1_Tue=S1_Wed=S1_Thu=S1_Fri=S1_Sat=S1_Sun=false;
   S4_Enabled=false; S5_Enabled=false;
#ifdef V119
   S1_RangeLow=S1_RangeHigh=S1_TPMoney=S1_SLMoney=S1_MaxSpread=0;
   S2_RangeLow=S2_RangeHigh=S2_TPMoney=S2_SLMoney=S2_MaxSpread=0;
   S3_RangeLow=S3_RangeHigh=S3_TPMoney=S3_SLMoney=S3_MaxSpread=0;
#endif
  }

// 2026-11-12（周四）服务器时间 = UTC+2。检查时刻 = 服务器 23:50（收盘 23:59，提前 9 分钟）
static long long srv(int d,int h,int m,int s=0)
  {
   MqlDateTime t; t.year=2026; t.mon=11; t.day=d; t.hour=h; t.min=m; t.sec=s;
   return (long long)StructToTime(t);
  }
static void setTimeServer(long long serverTime) { SIMG.utcMs=(serverTime-SIMG.serverOffsetSec)*1000; }

static void world()
  {
   SIMG.reset();
   g_blockedKeys.v.clear(); g_blockedStates.v.clear();   // 模拟“终端全新启动”：清掉上一个场景留在 EA 进程内存里的封锁记录
   SimSymbol n; n.bid=28500.00; n.ask=28502.20; n.vmin=0.1; n.vstep=0.1; n.tvWin=n.tvLoss=0.01;      // 1 手 1 价格单位 = 1 USD
   SIMG.sym[NAS]=n;
   SimSymbol x; x.bid=4155.00; x.ask=4155.69; x.vmin=1.0; x.vstep=1.0; x.tvWin=x.tvLoss=0.01;
   SIMG.sym[XAU]=x;
   SimSymbol a; a.digits=0; a.point=1; a.tickSize=1; a.bid=15000; a.ask=15011; a.vmin=0.01; a.vstep=0.01; a.tvWin=a.tvLoss=1.0;
   SIMG.sym[A50]=a;
   SimSymbol o; o.digits=3; o.point=0.001; o.tickSize=0.001; o.bid=161.250; o.ask=161.262; o.vmin=0.01; o.vstep=0.01;
   o.tvWin=0.6203; o.tvLoss=0.6211;                                                                    // 非美元计价、盈亏两侧换算率不同
   SIMG.sym[ODD]=o;
   setTimeServer(srv(12,23,45));
   clearInputs();
  }

static int  init() { int r=OnInit(); SIMG.tickCalls=0; return r; }
static void run(int seconds) { for(int k=0;k<seconds;k++) { SIMG.utcMs+=1000; OnTimer(); } }
static void done() { OnDeinit(0); }

static std::string fp()
  {
   std::ostringstream o;
   o.setf(std::ios::fixed); o.precision(3);
   for(auto &kv:SIMG.gv) if(kv.first.rfind("SCE_",0)==0) o<<kv.first<<"="<<(int)kv.second<<";";
   for(auto &r:SIMG.orders) o<<" ["<<r.kind.utf8()<<" "<<r.sym.utf8()<<" t"<<r.type<<" v"<<r.vol<<" p"<<r.price<<" sl"<<r.sl<<" tp"<<r.tp<<" rc"<<r.retcode<<"]";
   for(auto &p:SIMG.pos) o<<" {pos "<<p.sym.utf8()<<" v"<<p.vol<<" o"<<p.open<<" sl"<<p.sl<<" tp"<<p.tp<<"}";
   return o.str();
  }
static int  evState(int slot=1,const char *date="20261112",const char *hhmm="2359")
  {
   std::string k="SCE_"+std::to_string(InpMagic)+"_"+std::to_string(slot)+"_"+date+"_"+hhmm;
   return SIMG.gv.count(k) ? (int)SIMG.gv[k] : 0;
  }
static int  opens() { int n=0; for(auto &r:SIMG.orders) if(r.kind.utf8()=="OPEN") n++; return n; }
static bool logHas(const char *s) { for(auto &l:SIMG.logs) if(l.find(s)!=std::string::npos) return true; return false; }
static bool panelHas(const char *s)
  {
   std::string all; for(auto &kv:SIMG.objText) all+=kv.second;
   // 面板文字按 60 字一段切开，查找前先把同一行的段拼起来
   std::map<int,std::map<int,std::string>> rows;
   for(auto &kv:SIMG.objText)
     {
      size_t a=kv.first.rfind('_'); size_t b=kv.first.rfind('_',a-1);
      rows[atoi(kv.first.substr(b+1,a-b-1).c_str())][atoi(kv.first.substr(a+1).c_str())]=kv.second;
     }
   for(auto &r:rows) { std::string line; for(auto &sgm:r.second) line+=sgm.second; if(line.find(s)!=std::string::npos) return true; }
   return false;
  }
static FILE *g_sample=nullptr;
// 把当前场景的 EA 日志和面板文字原样存入样例文件（供测试报告引用）
static void sample(const char *title)
  {
   if(!g_sample) g_sample=fopen("build/sample_logs.txt","w");
   fprintf(g_sample,"\n######## %s ########\n--- 日志 ---\n",title);
   for(auto &l:SIMG.logs) if(l.find("品种1")!=std::string::npos || l.find("提示：本图表")!=std::string::npos) fprintf(g_sample,"%s\n",l.c_str());
   fprintf(g_sample,"--- 面板 ---\n");
   std::map<int,std::map<int,std::string>> rows;
   for(auto &kv:SIMG.objText)
     {
      size_t a=kv.first.rfind('_'); size_t b=kv.first.rfind('_',a-1);
      rows[atoi(kv.first.substr(b+1,a-b-1).c_str())][atoi(kv.first.substr(a+1).c_str())]=kv.second;
     }
   for(auto &r:rows) { std::string line; for(auto &sgm:r.second) line+=sgm.second; fprintf(g_sample,"%s\n",line.c_str()); }
  }
static void R(const char *name) { std::cout<<"REG "<<name<<" :: "<<fp()<<"\n"; }
static void check(const char *name,bool ok,const std::string &extra="")
  {
   (ok ? g_pass : g_fail)++;
   std::cout<<(ok ? "PASS " : "FAIL ")<<name<<(extra.empty() ? "" : " :: "+extra)<<"\n";
  }
static bool near(double a,double b,double tol=1e-6) { return std::fabs(a-b)<=tol; }

// 纳指卖出、≥阈值、价格差止盈止损（旧功能典型用法）
static void nasSellGte(double thr=28370) { slot1(true,0,NAS,"2026.11.12","23:59",9,COND_GTE,thr,DIR_SELL,LOT_FIXED,0.1,STOPS_DISTANCE,0,0,300,150); }

//======================================================================
//  旧功能回归（v1.18 与 v1.19 的输出必须一致）
//======================================================================
static void regression()
  {
   world(); nasSellGte(); init(); run(600); R("R01 ≥阈值 卖出 满足 价格差止盈止损 成交"); done();
   world(); nasSellGte(29000); init(); run(600); R("R02 ≥阈值 不满足"); done();
   world(); slot1(true,0,XAU,"2026.11.12","23:59",14,COND_LTE,4160,DIR_BUY,LOT_FIXED,1.0,STOPS_PRICE,4215.00,4125.00,0,0);
            setTimeServer(srv(12,23,40)); init(); run(600); R("R03 ≤阈值 买入 固定止盈止损价 成交"); done();
   world(); slot1(true,0,A50,"2026.11.12","23:14",14,COND_ALWAYS,0,DIR_BUY,LOT_MIN,0,STOPS_DISTANCE,0,0,300,300);
            setTimeServer(srv(12,22,55)); init(); run(600); R("R04 到点直接执行 最小手数 价格差"); done();
   world(); nasSellGte(); InpRunMode=RUN_SIGNAL_ONLY; init(); run(600); R("R05 仅记录信号"); done();
   world(); nasSellGte(); setTimeServer(srv(12,23,49,50)); init(); run(600); R("R06 检查前10秒才启动 → 已错过"); done();
   world(); slot1(true,0,NAS,"2026.11.05","23:59",9,COND_GTE,28370,DIR_SELL,LOT_FIXED,0.1,STOPS_DISTANCE,0,0,300,150);
            init(); run(600); R("R07 日期已过的一次性任务 → 已错过"); done();
   world(); nasSellGte(); SIMG.pos.push_back(SimPos{77,77,string(NAS),InpMagic,POSITION_TYPE_SELL,0.1,28000,28150,27700});
            init(); run(600); R("R08 已有本EA持仓 → 跳过"); done();
   world(); nasSellGte(); init(); run(310); done(); SIMG.pos.clear(); init(); run(300); R("R09 成交后同窗口内重新加载 → 不重复下单"); done();
   world(); nasSellGte(); SIMG.slip=1.50; init(); run(600); R("R10 滑点成交 → 按实际成交价调整止盈止损"); done();
   world(); nasSellGte(); SIMG.sym[NAS].tickAgeSec=600; init(); run(600); R("R11 报价一直过期 → 已错过"); done();
   world(); nasSellGte(); SIMG.sym[NAS].sessTo=23*3600+30*60; init(); run(600); R("R12 不在交易时段 → 跳过"); done();
   world(); nasSellGte(); SIMG.rejectRetcode=TRADE_RETCODE_MARKET_CLOSED; init(); run(600); R("R13 下单被拒 → 不重试"); done();
   world(); slot1(true,0,XAU,"2026.11.12","23:59",14,COND_LTE,4160,DIR_BUY,LOT_FIXED,1.0,STOPS_PRICE,4215.00,4125.00,0,0);
            SIMG.stripStops=true; setTimeServer(srv(12,23,40)); init(); run(600); R("R14 成交未带止盈止损 → 补设"); done();
   world(); slot1(true,0,XAU,"2026.11.12","23:59",14,COND_LTE,4160,DIR_BUY,LOT_FIXED,1.0,STOPS_PRICE,4215.00,4125.00,0,0);
            SIMG.stripStops=true; SIMG.failModify=true; setTimeServer(srv(12,23,40)); init(); run(600); R("R15 补设失败 → 平仓并确认"); done();
   world(); nasSellGte(); init(); run(290); SIMG.utcMs+=40*1000; run(400); R("R16 检查时刻前后电脑停顿40秒（23:49:50→23:50:30）→ 已错过"); done();
   world(); nasSellGte(); init(); run(200); SIMG.utcMs+=40*1000; run(400); R("R16b 停顿在检查前60秒结束、之后连续运行满30秒 → 重新就绪并正常执行"); done();
   world(); nasSellGte(); SIMG.demo=false; init(); run(600); R("R17 仅限模拟账户 + 真实账户 → 跳过"); done();
   world(); nasSellGte(); SIMG.termTrade=false; init(); run(600); R("R18 算法交易按钮关闭 → 跳过"); done();
   world(); nasSellGte(); SIMG.connected=false; init(); run(600); R("R19 断线 → 已错过"); done();
   world(); nasSellGte(); SIMG.gvWriteFail=true; init(); run(600); R("R20 防重复记录写入失败 → 禁止下单"); done();
   world(); nasSellGte(); SIMG.freeMargin=1; init(); run(600); R("R21 保证金不足 → 跳过"); done();
   world(); slot1(true,0,NAS,"2026.11.12","23:59",9,COND_GTE,28370,DIR_SELL,LOT_FIXED,0.15,STOPS_DISTANCE,0,0,300,150);
            init(); run(600); R("R22 手数不合步长 → 参数无效"); done();
   world(); slot1(true,0,NAS,"2026.11.12","23:59",9,COND_GTE,28370,DIR_SELL,LOT_FIXED,0.1,STOPS_DISTANCE,0,0,1,1);
            SIMG.sym[NAS].stopsLevel=500; init(); run(600); R("R23 止损距离小于券商最小距离 → 跳过"); done();
   // 按星期重复（已有功能，保留）：只勾周四，跑到周五收盘后——周四成交一次，周五不执行
   world(); slot1(true,EXEC_WEEKLY,NAS,"","23:59",9,COND_GTE,28370,DIR_SELL,LOT_FIXED,0.1,STOPS_DISTANCE,0,0,300,150); S1_Thu=true;
            init(); run(600); SIMG.pos.clear(); run(86400); R("R24 按星期重复：只在勾选日执行"); done();
   // 一次性任务跨多日运行：只执行一次
   world(); nasSellGte(); init(); run(600); SIMG.pos.clear(); run(2*86400); R("R25 一次性任务连续运行两天 → 只执行一次"); done();
   // 多组 + 净额账户
   world(); nasSellGte(); slot2(true,0,XAU,"2026.11.12","23:59",9,COND_GTE,4100,DIR_SELL,LOT_FIXED,1.0,STOPS_DISTANCE,0,0,60,30);
            init(); run(600); R("R26 两组不同品种同刻触发"); done();
   world(); nasSellGte(); SIMG.hedging=false; SIMG.pos.push_back(SimPos{88,88,string(NAS),555,POSITION_TYPE_BUY,0.1,28000,0,0});
            init(); run(600); R("R27 净额账户已有他人持仓 → 跳过"); done();
   world(); nasSellGte(); SIMG.gv["SCE_26109901_1_20261112_2359"]=ST_SENDING; init(); run(600); R("R31 遗留“发送中”记录（上次下单过程中崩溃）→ 不再下单"); done();
   world(); nasSellGte(); SIMG.sym[NAS].tickAgeSec=600; init(); run(320); SIMG.sym[NAS].tickAgeSec=0; run(300); R("R32 窗口内报价先过期后恢复 → 恢复后判断一次并执行"); done();
   // 三个实例 2026-11-11 的实况参数（日期全部已过）：加载后不得下单
   world(); InpMagic=26102301; InpDemoOnly=false; SIMG.demo=false;
            slot1(true,0,NAS,"2026.10.28","05:00",120,COND_GTE,29256,DIR_SELL,LOT_FIXED,0.1,STOPS_DISTANCE,0,0,450,150); S1_TimeZone=TZ_BEIJING;
            slot3(true,0,NAS,"2026.11.05","03:05",5,COND_GTE,28370,DIR_SELL,LOT_FIXED,0.1,STOPS_DISTANCE,0,0,300,150); S3_TimeZone=TZ_BEIJING;
            SIMG.gv["SCE_26102301_3_20261105_0305"]=ST_SENT_OK;
            init(); run(900); R("R28 纳指实例实况参数（S1 无记录 / S3 已有成交记录）→ 不下单"); done();
   world(); InpMagic=26102401; InpDemoOnly=false; SIMG.demo=false;
            slot1(true,0,XAU,"2026.10.28","05:00",120,COND_GTE,4055,DIR_SELL,LOT_FIXED,1.0,STOPS_DISTANCE,0,0,45,20); S1_TimeZone=TZ_BEIJING;
            init(); run(900); R("R29 黄金实例实况参数 → 不下单"); done();
   world(); InpMagic=26102201; InpDemoOnly=false; SIMG.demo=false;
            slot2(true,0,A50,"2026.11.04","12:05",5,COND_ALWAYS,0,DIR_BUY,LOT_FIXED,0.01,STOPS_DISTANCE,0,0,300,300); S2_TimeZone=TZ_BEIJING;
            init(); run(900); R("R30 A50 实例实况参数 → 不下单"); done();
  }

#ifdef V119
//======================================================================
//  v1.19 新功能
//======================================================================
static void nasRangeSell(double lo=27960,double hi=29190)
  {
   slot1(true,0,NAS,"2026.11.12","23:59",9,COND_RANGE,0,DIR_SELL,LOT_FIXED,0.1,STOPS_DISTANCE,0,0,300,150);
   S1_RangeLow=lo; S1_RangeHigh=hi;
  }
static void nasMoney(int cond=COND_ALWAYS)
  {
   slot1(true,0,NAS,"2026.11.12","23:59",9,cond,0,DIR_SELL,LOT_FIXED,0.1,STOPS_MONEY,0,0,0,0);
   S1_TPMoney=60; S1_SLMoney=20;
  }

static void features()
  {
   // ---------- 1. 双边价格区间 ----------
   world(); nasRangeSell(); init(); run(600);
   check("N01 区间内（27960 ≤ Bid 28500 ≤ 29190）卖出成交",evState()==ST_SENT_OK && opens()==1 && near(SIMG.pos[0].sl,28650) && near(SIMG.pos[0].tp,28200),fp()); done();
   world(); nasRangeSell(); SIMG.sym[NAS].bid=27959.99; SIMG.sym[NAS].ask=27962.19; init(); run(600);
   check("N02 低于最低价 → 不下单",evState()==ST_NOT_MET && opens()==0 && logHas("价格条件不满足"),fp()); done();
   world(); nasRangeSell(); SIMG.sym[NAS].bid=29190.01; SIMG.sym[NAS].ask=29192.21; init(); run(600);
   check("N03 高于最高价 → 不下单",evState()==ST_NOT_MET && opens()==0,fp()); done();
   world(); nasRangeSell(); SIMG.sym[NAS].bid=27960.00; SIMG.sym[NAS].ask=27962.20; init(); run(600);
   check("N04 恰好等于最低价 → 满足",evState()==ST_SENT_OK && opens()==1,fp()); done();
   world(); nasRangeSell(); SIMG.sym[NAS].bid=29190.00; SIMG.sym[NAS].ask=29192.20; init(); run(600);
   check("N05 恰好等于最高价 → 满足",evState()==ST_SENT_OK && opens()==1,fp()); done();
   // 买入用 Ask 判断：Bid 在区间内但 Ask 超出上限 → 不满足
   world(); slot1(true,0,NAS,"2026.11.12","23:59",9,COND_RANGE,0,DIR_BUY,LOT_FIXED,0.1,STOPS_DISTANCE,0,0,300,150);
   S1_RangeLow=28000; S1_RangeHigh=28501; init(); run(600);
   check("N06 买入按 Ask 判断区间（Bid 28500 在内、Ask 28502.2 超出）→ 不下单",evState()==ST_NOT_MET && opens()==0,fp()); done();
   // 检查时满足，发单前价格跌出区间
   world(); nasRangeSell(); init();
   SIMG.onTick=[](int n){ if(n>=2) { SIMG.sym[NAS].bid=27950.00; SIMG.sym[NAS].ask=27952.20; } };
   run(600);
   check("N07 检查时在区间内、发单前跌出区间 → 不下单且任务结束",evState()==ST_NOT_MET && opens()==0 && logHas("发单前复核：价格条件已不满足"),fp());
   sample("N07 检查时在区间内、发单前跌出区间");
   run(600); check("N07b 之后价格回到区间也不补单",opens()==0); done();
   world(); nasRangeSell(); init();
   SIMG.onTick=[](int n){ if(n>=2) { SIMG.sym[NAS].bid=29300.00; SIMG.sym[NAS].ask=29302.20; } };
   run(600); check("N08 发单前涨出区间上限 → 不下单",evState()==ST_NOT_MET && opens()==0,fp()); done();
   // 单边条件同样在发单前复核
   world(); nasSellGte(28370); init();
   SIMG.onTick=[](int n){ if(n>=2) { SIMG.sym[NAS].bid=28369.00; SIMG.sym[NAS].ask=28371.20; } };
   run(600); check("N09 单边 ≥ 条件：发单前跌破阈值 → 不下单",evState()==ST_NOT_MET && opens()==0,fp()); done();
   // 参数校验
   world(); nasRangeSell(29190,27960); init(); run(600);
   check("N10 区间上下限填反 → 参数无效，不检查不下单",opens()==0 && evState()==0 && logHas("必须大于最低价"),fp()); done();
   world(); nasRangeSell(0,29190); init(); run(600);
   check("N11 区间只填一边 → 参数无效",opens()==0 && evState()==0 && logHas("都必须填写"),fp()); done();

   // ---------- 2. 账户货币金额止盈止损 ----------
   world(); nasMoney(); init(); run(600);
   {
    bool ok=evState()==ST_SENT_OK && opens()==1 && SIMG.pos.size()==1;
    double a=0,b=0;
    if(ok) { OrderCalcProfit(ORDER_TYPE_SELL,string(NAS),0.1,SIMG.pos[0].open,SIMG.pos[0].tp,a); OrderCalcProfit(ORDER_TYPE_SELL,string(NAS),0.1,SIMG.pos[0].open,SIMG.pos[0].sl,b); }
    check("N12 纳指 0.1 手卖出，盈利60/亏损20 → 止盈距离600、止损距离200，核算 +60.00 / -20.00",
          ok && near(SIMG.pos[0].tp,28500-600) && near(SIMG.pos[0].sl,28500+200) && near(a,60) && near(b,-20) && logHas("金额换算（OrderCalcProfit"),fp());
   }
   done();
   world(); nasMoney(); SIMG.slip=2.50; init(); run(600);
   {
    bool ok=evState()==ST_SENT_OK && SIMG.pos.size()==1;
    double a=0,b=0;
    if(ok) { OrderCalcProfit(ORDER_TYPE_SELL,string(NAS),0.1,SIMG.pos[0].open,SIMG.pos[0].tp,a); OrderCalcProfit(ORDER_TYPE_SELL,string(NAS),0.1,SIMG.pos[0].open,SIMG.pos[0].sl,b); }
    check("N13 金额模式 + 滑点 2.5：成交后按实际成交价重新定位，核算仍为 +60 / -20",
          ok && near(SIMG.pos[0].open,28497.5) && near(a,60) && near(b,-20) && logHas("按实际成交价 28497.50 核算"),fp());
    sample("N13 金额模式 + 滑点 2.5");
   }
   done();
   world(); slot1(true,0,XAU,"2026.11.12","23:59",14,COND_ALWAYS,0,DIR_BUY,LOT_FIXED,1.0,STOPS_MONEY,0,0,0,0); S1_TPMoney=60; S1_SLMoney=30;
   setTimeServer(srv(12,23,40)); init(); run(600);
   check("N14 黄金 1 手买入，盈利60/亏损30 → 止盈 Ask+60、止损 Ask-30",
         evState()==ST_SENT_OK && SIMG.pos.size()==1 && near(SIMG.pos[0].tp,4155.69+60) && near(SIMG.pos[0].sl,4155.69-30),fp()); done();
   world(); slot1(true,0,A50,"2026.11.12","23:14",14,COND_ALWAYS,0,DIR_BUY,LOT_MIN,0,STOPS_MONEY,0,0,0,0); S1_TPMoney=3; S1_SLMoney=3;
   setTimeServer(srv(12,22,55)); init(); run(600);
   check("N15 A50 最小手数(0.01)买入，盈利3/亏损3 → 距离 300 / 300",
         evState(1,"20261112","2314")==ST_SENT_OK && SIMG.pos.size()==1 && near(SIMG.pos[0].vol,0.01) && near(SIMG.pos[0].tp,15011+300) && near(SIMG.pos[0].sl,15011-300),fp()); done();
   world(); slot1(true,0,ODD,"2026.11.12","23:59",9,COND_ALWAYS,0,DIR_SELL,LOT_FIXED,0.03,STOPS_MONEY,0,0,0,0); S1_TPMoney=25; S1_SLMoney=10;
   init(); run(600);
   {
    bool ok=evState()==ST_SENT_OK && SIMG.pos.size()==1;
    double a=0,b=0;
    if(ok) { OrderCalcProfit(ORDER_TYPE_SELL,string(ODD),0.03,SIMG.pos[0].open,SIMG.pos[0].tp,a); OrderCalcProfit(ORDER_TYPE_SELL,string(ODD),0.03,SIMG.pos[0].open,SIMG.pos[0].sl,b); }
    char buf[96]; snprintf(buf,sizeof buf,"核算 止盈=%.2f 止损=%.2f",a,b);
    check("N16 非整数换算率品种（盈亏两侧换算率不同，0.03 手）：止损核算不超过 10，止盈偏差不超过半个最小变动",
          ok && b<=0 && -b<=10.011 && -b>=10-0.03 && std::fabs(a-25)<=0.02,buf);
   }
   done();
   world(); nasMoney(); S1_TPMoney=60; S1_SLMoney=0.0001; init(); run(600);
   check("N17 止损金额小于一个最小价格变动 → 不下单",evState()==ST_SKIPPED && opens()==0 && logHas("小于一个最小价格变动对应的盈亏"),fp()); done();
   world(); nasMoney(); S1_SLMoney=0; init(); run(600);
   check("N18 金额模式未填止损金额 → 参数无效",evState()==0 && opens()==0 && logHas("止损金额为必填项"),fp()); done();
   world(); nasMoney(); SIMG.failCalcProfit=true; init(); run(600);
   check("N19 OrderCalcProfit 计算失败 → 不下单",evState()==ST_SKIPPED && opens()==0 && logHas("OrderCalcProfit 计算失败"),fp()); done();
   world(); nasMoney(); S1_SLMoney=0.5; SIMG.sym[NAS].stopsLevel=1000; init(); run(600);
   check("N20 金额换算出的止损距离(5)小于券商最小止损距离(10) → 不下单、不放大距离",evState()==ST_SKIPPED && opens()==0 && logHas("券商最小止损距离"),fp()); done();
   world(); nasMoney(COND_RANGE); S1_RangeLow=27960; S1_RangeHigh=29190; S1_MaxSpread=3.0; init(); run(600);
   check("N21 组合：区间 + 金额止盈止损 + 点差上限 全部满足 → 成交",
         evState()==ST_SENT_OK && opens()==1 && near(SIMG.pos[0].tp,27900) && near(SIMG.pos[0].sl,28700),fp());
   sample("N21 纳指卖出 0.1 手：区间 27960–29190 + 盈利60/亏损20 + 点差上限 3.0，全部满足"); done();
   // 金额模式下成交后调整失败/成交不带保护
   world(); nasMoney(); SIMG.slip=2.50; SIMG.failModify=true; init(); run(600);
   check("N21b 金额模式 + 滑点 + 改单被拒 → 保留原有双边保护，不平仓，标记“距离未精确调整”",
         evState()==ST_STOPS_INEXACT && SIMG.pos.size()==1 && SIMG.pos[0].sl>0 && SIMG.pos[0].tp>0,fp()); done();
   world(); nasMoney(); SIMG.stripStops=true; init(); run(600);
   check("N21c 金额模式 + 成交未带止盈止损 → 按实际成交价补设",
         evState()==ST_SENT_OK && SIMG.pos.size()==1 && near(SIMG.pos[0].tp,27900) && near(SIMG.pos[0].sl,28700),fp()); done();
   world(); nasMoney(); SIMG.stripStops=true; SIMG.failModify=true; init(); run(600);
   check("N21d 金额模式 + 成交未带止盈止损 + 补设失败 → 平仓并确认",evState()==ST_CLOSED_NO_STOPS && SIMG.pos.empty(),fp()); done();

   // ---------- 3. 最大允许点差 ----------
   world(); nasSellGte(); S1_MaxSpread=2.0; init(); run(600);
   check("N22 点差 2.20 > 上限 2.00 → 不下单并记录原因",evState()==ST_SKIPPED && opens()==0 && logHas("点差超限：当前点差 2.20"),fp()); done();
   world(); nasSellGte(); S1_MaxSpread=2.2; init(); run(600);
   check("N23 点差恰好等于上限 → 允许",evState()==ST_SENT_OK && opens()==1,fp()); done();
   world(); nasSellGte(); S1_MaxSpread=3.0; init();
   SIMG.onTick=[](int n){ if(n>=2) SIMG.sym[NAS].ask=28504.50; };
   run(600);
   check("N24 检查时点差合格、发单前扩大到 4.50 → 不下单",evState()==ST_SKIPPED && opens()==0 && logHas("发单前安全复核未通过") && logHas("点差超限：当前点差 4.50"),fp()); done();
   world(); nasSellGte(); S1_MaxSpread=-1; init(); run(600);
   check("N25 点差上限为负 → 参数无效",evState()==0 && opens()==0 && logHas("不能为负数"),fp()); done();
   world(); nasSellGte(29000); S1_MaxSpread=2.0; init(); run(600);
   check("N26 价格不满足且点差超限 → 记为条件不满足",evState()==ST_NOT_MET && opens()==0,fp()); done();

   // ---------- 4. 发单前安全复核 ----------
   world(); nasSellGte(); init();
   SIMG.onTick=[](int n){ if(n==2 && SIMG.pos.empty()) SIMG.pos.push_back(SimPos{91,91,string(NAS),InpMagic,POSITION_TYPE_SELL,0.1,28400,28550,28100}); };
   run(600); check("N27 检查后、发单前出现本EA持仓 → 不下单",evState()==ST_SKIPPED && opens()==0 && logHas("已有本EA持仓"),fp()); done();
   world(); nasSellGte(); init();
   SIMG.onTick=[](int n){ if(n==2) SIMG.termTrade=false; };
   run(600); check("N28 发单前算法交易被关闭 → 不下单",evState()==ST_SKIPPED && opens()==0 && logHas("算法交易"),fp()); done();
   world(); nasSellGte(); init();
   SIMG.onTick=[](int n){ if(n==2) SIMG.sym[NAS].tradeMode=SYMBOL_TRADE_MODE_CLOSEONLY; };
   run(600); check("N29 发单前品种变为只允许平仓 → 不下单",evState()==ST_SKIPPED && opens()==0 && logHas("只允许平仓"),fp()); done();
   world(); nasSellGte(); init();
   SIMG.onTick=[](int n){ if(n==2) SIMG.sym[NAS].hasTick=false; };
   run(600); check("N30 发单前取不到报价 → 不下单",evState()==ST_SKIPPED && opens()==0 && logHas("下单前取不到有效报价"),fp()); done();
   world(); slot1(true,0,XAU,"2026.11.12","23:59",14,COND_LTE,4160,DIR_BUY,LOT_FIXED,1.0,STOPS_PRICE,4215.00,4125.00,0,0);
   setTimeServer(srv(12,23,40)); init();
   SIMG.onTick=[](int n){ if(n>=2) { SIMG.sym[XAU].bid=4124.00; SIMG.sym[XAU].ask=4124.69; } };
   run(600); check("N31 固定止损价模式：发单前价格已跌破止损价 → 不下单（v1.18 会交给券商拒单）",evState()==ST_SKIPPED && opens()==0 && logHas("止损价 4125.00 不合法"),fp()); done();
   world(); nasRangeSell(); S1_MaxSpread=3; init(); run(600); SIMG.pos.clear(); done(); init(); run(600); SIMG.pos.clear(); run(2*86400);
   check("N32 新功能任务：成交后重新加载并继续运行两天 → 只执行一次",opens()==1,fp()); done();
   world(); nasRangeSell(); setTimeServer(srv(12,23,49,50)); init(); run(600);
   check("N33 新功能任务：检查前 10 秒才启动 → 已错过，不补单",evState()==ST_MISSED && opens()==0,fp()); done();
   world(); nasRangeSell(); InpRunMode=RUN_SIGNAL_ONLY; init(); run(600);
   check("N34 新功能任务 + 仅记录信号模式 → 不下单",evState()==ST_SIGNAL && opens()==0,fp()); done();

   // ---------- 5. 日志与面板 ----------
   world(); nasRangeSell(); S1_MaxSpread=2.0; init(); run(600);
   check("N35 日志含：检查时刻、检查报价、允许区间、点差及上限、原因",
         logHas("检查时刻：北京") && logHas("判断用价 Bid=28500.00") && logHas("27960.00 ≤ Bid ≤ 29190.00") && logHas("点差=2.20（220 点），上限 2") && logHas("原因：点差超限"),"");
   check("N36 面板含：区间、点差上限、本次结果与未执行原因",
         panelHas("27960.00 ≤ Bid ≤ 29190.00") && panelHas("点差上限 2") && panelHas("本次结果：条件满足但点差超限，未下单") && panelHas("原因：点差超限"),"");
   sample("N35 区间满足但点差 2.20 超过上限 2.00"); done();
   world(); nasMoney(); init(); run(600);
   check("N37 面板显示金额止盈止损设定",panelHas("止盈 盈利60 止损 亏损20（账户货币金额 USD）"),""); done();

   // ---------- 6. 图表品种与任务品种不一致 ----------
   world(); nasRangeSell(); SIMG.chartSymbol="XAUUSD"; SIMG.sym[XAU].hasTick=false; init(); run(600);
   check("N38 纳指任务挂在 XAUUSD 图表、且黄金完全没有报价 → 仍按时触发并成交，日志有提示",
         evState()==ST_SENT_OK && opens()==1 && logHas("本图表品种为 [XAUUSD]"),fp()); done();
  }
#endif

int main()
  {
   regression();
#ifdef V119
   features();
   std::cout<<"SUMMARY v1.19 feature checks: "<<g_pass<<" passed, "<<g_fail<<" failed\n";
#endif
   return g_fail ? 1 : 0;
  }

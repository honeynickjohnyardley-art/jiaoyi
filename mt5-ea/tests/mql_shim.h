// MQL5 兼容层 + 券商模拟器（仅用于在 Linux 上对 EA 逻辑做离线模拟测试）。
// 这不是 MetaEditor，也不是真实券商环境：它只实现了 SessionCloseEntry 用到的那部分 MQL5 接口。
#pragma once
#include <string>
#include <vector>
#include <map>
#include <functional>
#include <cmath>
#include <cstdio>
#include <cstdint>
#include <ctime>

typedef long long          datetime;
typedef unsigned long      ulong;
typedef unsigned int       uint;
typedef unsigned short     ushort;
typedef unsigned int       color;

//==================== string（按 Unicode 字符计长度，与 MQL5 的 UTF-16 行为对本项目等价） ====================
struct string
  {
   std::u32string s;
   string() {}
   string(const char *u) { s=dec(u); }
   string(const std::string &u) { s=dec(u.c_str()); }
   static std::u32string dec(const char *p)
     {
      std::u32string o;
      const unsigned char *c=(const unsigned char*)p;
      while(*c)
        {
         char32_t v;
         int n;
         if(*c<0x80) { v=*c; n=1; }
         else if((*c>>5)==6) { v=*c&0x1F; n=2; }
         else if((*c>>4)==14) { v=*c&0x0F; n=3; }
         else { v=*c&0x07; n=4; }
         for(int k=1;k<n;k++) v=(v<<6)|(c[k]&0x3F);
         o.push_back(v);
         c+=n;
        }
      return o;
     }
   std::string utf8() const
     {
      std::string o;
      for(char32_t v:s)
        {
         if(v<0x80) o.push_back((char)v);
         else if(v<0x800) { o.push_back((char)(0xC0|(v>>6))); o.push_back((char)(0x80|(v&0x3F))); }
         else if(v<0x10000) { o.push_back((char)(0xE0|(v>>12))); o.push_back((char)(0x80|((v>>6)&0x3F))); o.push_back((char)(0x80|(v&0x3F))); }
         else { o.push_back((char)(0xF0|(v>>18))); o.push_back((char)(0x80|((v>>12)&0x3F))); o.push_back((char)(0x80|((v>>6)&0x3F))); o.push_back((char)(0x80|(v&0x3F))); }
        }
      return o;
     }
   string &operator+=(const string &o) { s+=o.s; return *this; }
   bool operator<(const string &o) const { return s<o.s; }
  };
inline string operator+(const string &a,const string &b) { string r; r.s=a.s+b.s; return r; }
inline bool operator==(const string &a,const string &b) { return a.s==b.s; }
inline bool operator!=(const string &a,const string &b) { return a.s!=b.s; }

template<typename T> struct DynArr
  {
   std::vector<T> v;
   T &operator[](long long i) { return v.at((size_t)i); }
  };
template<typename T> int ArraySize(DynArr<T> &a) { return (int)a.v.size(); }
template<typename T> int ArrayResize(DynArr<T> &a,int n) { a.v.resize((size_t)n); return n; }
template<typename T> void ZeroMemory(T &t) { t=T(); }

//==================== 常量 ====================
enum
  {
   // SymbolInfo
   SYMBOL_POINT=100,SYMBOL_TRADE_TICK_SIZE,SYMBOL_TRADE_TICK_VALUE,SYMBOL_VOLUME_MIN,SYMBOL_VOLUME_MAX,SYMBOL_VOLUME_STEP,
   SYMBOL_DIGITS,SYMBOL_TRADE_STOPS_LEVEL,SYMBOL_TRADE_FREEZE_LEVEL,SYMBOL_FILLING_MODE,SYMBOL_TRADE_MODE,
   // Account / Terminal / MQL
   ACCOUNT_MARGIN_MODE=200,ACCOUNT_TRADE_MODE,ACCOUNT_TRADE_ALLOWED,ACCOUNT_TRADE_EXPERT,ACCOUNT_LOGIN,ACCOUNT_MARGIN_FREE,ACCOUNT_CURRENCY,
   TERMINAL_CONNECTED=300,TERMINAL_TRADE_ALLOWED,MQL_TRADE_ALLOWED,
   // Position
   POSITION_SYMBOL=400,POSITION_MAGIC,POSITION_IDENTIFIER,POSITION_VOLUME,POSITION_SL,POSITION_TP,POSITION_PRICE_OPEN,POSITION_TYPE,
   // Deal / Order
   DEAL_SYMBOL=500,DEAL_MAGIC,DEAL_ENTRY,DEAL_TIME,DEAL_VOLUME,DEAL_ORDER,DEAL_REASON,ORDER_SYMBOL,ORDER_MAGIC,
   // Object / chart
   OBJ_LABEL=600,OBJPROP_CORNER,OBJPROP_ANCHOR,OBJPROP_SELECTABLE,OBJPROP_HIDDEN,OBJPROP_BACK,OBJPROP_FONT,OBJPROP_FONTSIZE,
   OBJPROP_XDISTANCE,OBJPROP_YDISTANCE,OBJPROP_COLOR,OBJPROP_TEXT,CORNER_LEFT_UPPER,ANCHOR_LEFT_UPPER,CHART_COLOR_FOREGROUND,
   LOG_LEVEL_ERRORS=700
  };
enum { SYMBOL_FILLING_FOK=1,SYMBOL_FILLING_IOC=2 };
enum ENUM_ORDER_TYPE_FILLING { ORDER_FILLING_FOK=0,ORDER_FILLING_IOC=1,ORDER_FILLING_RETURN=2 };
enum ENUM_ORDER_TYPE { ORDER_TYPE_BUY=0,ORDER_TYPE_SELL=1 };
enum { POSITION_TYPE_BUY=0,POSITION_TYPE_SELL=1 };
enum { SYMBOL_TRADE_MODE_DISABLED=0,SYMBOL_TRADE_MODE_LONGONLY,SYMBOL_TRADE_MODE_SHORTONLY,SYMBOL_TRADE_MODE_CLOSEONLY,SYMBOL_TRADE_MODE_FULL };
enum { ACCOUNT_MARGIN_MODE_RETAIL_NETTING=0,ACCOUNT_MARGIN_MODE_EXCHANGE=1,ACCOUNT_MARGIN_MODE_RETAIL_HEDGING=2 };
enum { ACCOUNT_TRADE_MODE_DEMO=0,ACCOUNT_TRADE_MODE_CONTEST=1,ACCOUNT_TRADE_MODE_REAL=2 };
enum { DEAL_ENTRY_IN=0,DEAL_ENTRY_OUT=1,DEAL_ENTRY_INOUT=2,DEAL_ENTRY_OUT_BY=3 };
enum { DEAL_REASON_CLIENT=0,DEAL_REASON_MOBILE,DEAL_REASON_WEB,DEAL_REASON_EXPERT,DEAL_REASON_SL,DEAL_REASON_TP,DEAL_REASON_SO };
enum { TRADE_ACTION_DEAL=1 };
enum { TRADE_RETCODE_PLACED=10008,TRADE_RETCODE_DONE=10009,TRADE_RETCODE_DONE_PARTIAL=10010,TRADE_RETCODE_ERROR=10011,
       TRADE_RETCODE_TIMEOUT=10012,TRADE_RETCODE_INVALID_STOPS=10016,TRADE_RETCODE_MARKET_CLOSED=10018,TRADE_RETCODE_CONNECTION=10031 };
enum { INIT_SUCCEEDED=0,INIT_FAILED=1,INIT_PARAMETERS_INCORRECT=32767 };
#undef SEEK_END
enum { FILE_READ=1,FILE_WRITE=2,FILE_TXT=4,FILE_SHARE_READ=8,FILE_SHARE_WRITE=16,SEEK_END=2,INVALID_HANDLE=-1 };
enum { TIME_DATE=1,TIME_MINUTES=2,TIME_SECONDS=4 };
enum { ERR_TRADE_POSITION_NOT_FOUND=4753 };
enum ENUM_DAY_OF_WEEK { SUNDAY=0,MONDAY,TUESDAY,WEDNESDAY,THURSDAY,FRIDAY,SATURDAY };

struct MqlDateTime { int year=0,mon=0,day=0,hour=0,min=0,sec=0,day_of_week=0,day_of_year=0; };
struct MqlTick { datetime time=0; double bid=0,ask=0,last=0; ulong volume=0; };
struct MqlTradeRequest { int action=0; ulong magic=0; string symbol; double volume=0,price=0,sl=0,tp=0; ulong deviation=0; int type=0; int type_filling=0; };
struct MqlTradeCheckResult { uint retcode=0; string comment; };

//==================== 模拟器状态 ====================
struct SimSymbol
  {
   int    digits=2;
   double point=0.01,tickSize=0.01;
   double tvWin=0.01,tvLoss=0.01;        // 每手、每个最小价格变动的盈/亏（账户货币）
   double vmin=0.1,vmax=100,vstep=0.1;
   int    stopsLevel=0,freezeLevel=0;
   int    tradeMode=SYMBOL_TRADE_MODE_FULL;
   double bid=0,ask=0;
   long long tickAgeSec=0;               // 报价比服务器时间旧多少秒
   bool   hasTick=true;
   long long sessFrom=3600,sessTo=86340; // 周一至周五 01:00–23:59
   bool   allDays=false;
  };
struct SimPos { ulong ticket; long id; string sym; long magic; int type; double vol,open,sl,tp; };
struct SimDeal { ulong ticket; string sym; long magic; int entry; datetime time; double vol; ulong order; int reason; long posId; };
struct SimOrderRec { string kind; string sym; int type; double vol,price,sl,tp; uint retcode; };

struct Sim
  {
   long long utcMs=0;
   int       serverOffsetSec=7200;
   std::map<std::string,SimSymbol> sym;
   std::map<std::string,double> gv;
   std::vector<SimPos> pos;
   std::vector<SimDeal> deals;
   std::vector<SimOrderRec> orders;      // EA 发出的全部交易请求
   std::vector<std::string> logs,alerts;
   std::map<std::string,std::string> objText;
   std::vector<SimDeal*> sel;
   int    selPos=-1;
   bool   connected=true,termTrade=true,mqlTrade=true,accTrade=true,accExpert=true,demo=true,hedging=true;
   double freeMargin=10000;
   uint   rejectRetcode=0;
   double slip=0;                        // 成交价对开仓方向不利的滑点（价格单位）
   bool   stripStops=false;              // 成交时不带止盈止损（测试补设流程）
   bool   failModify=false;
   bool   failCalcProfit=false;
   bool   gvWriteFail=false;
   int    lastError=0;
   ulong  nextTicket=1000;
   int    tickCalls=0;
   std::function<void(int)> onTick;      // 每次 EA 读取报价前调用（参数为第几次读取），用于模拟价格在检查与发单之间变化
   std::string chartSymbol="XAUUSD";
   void reset() { *this=Sim(); }
   datetime utc() const { return utcMs/1000; }
  };
extern Sim SIMG;
#define _Symbol (string(SIMG.chartSymbol))

//==================== 时间 ====================
inline datetime TimeGMT() { return SIMG.utc(); }
inline datetime TimeTradeServer() { return SIMG.utc()+SIMG.serverOffsetSec; }
inline datetime TimeLocal() { return SIMG.utc()+8*3600; }
inline ulong GetTickCount64() { return (ulong)SIMG.utcMs+5000000; }
inline ulong GetMicrosecondCount() { return (ulong)SIMG.utcMs*1000+777; }
inline bool TimeToStruct(datetime t,MqlDateTime &s)
  {
   time_t tt=(time_t)t; struct tm m; gmtime_r(&tt,&m);
   s.year=m.tm_year+1900; s.mon=m.tm_mon+1; s.day=m.tm_mday; s.hour=m.tm_hour; s.min=m.tm_min; s.sec=m.tm_sec;
   s.day_of_week=m.tm_wday; s.day_of_year=m.tm_yday; return true;
  }
inline datetime StructToTime(MqlDateTime &s)
  {
   struct tm m={}; m.tm_year=s.year-1900; m.tm_mon=s.mon-1; m.tm_mday=s.day; m.tm_hour=s.hour; m.tm_min=s.min; m.tm_sec=s.sec;
   return (datetime)timegm(&m);
  }
inline string TimeToString(datetime t,int flags=TIME_DATE|TIME_MINUTES)
  {
   MqlDateTime s; TimeToStruct(t,s); char b[64]; std::string o;
   if(flags&TIME_DATE) { snprintf(b,sizeof b,"%04d.%02d.%02d",s.year,s.mon,s.day); o+=b; }
   if(flags&(TIME_MINUTES|TIME_SECONDS)) { snprintf(b,sizeof b,"%s%02d:%02d",o.empty()?"":" ",s.hour,s.min); o+=b; }
   if(flags&TIME_SECONDS) { snprintf(b,sizeof b,":%02d",s.sec); o+=b; }
   return string(o);
  }

//==================== 数学 / 字符串 ====================
inline double MathRound(double v) { return std::round(v); }
inline double MathFloor(double v) { return std::floor(v); }
inline double MathAbs(double v) { return std::fabs(v); }
inline double NormalizeDouble(double v,int d) { double p=std::pow(10.0,d); return std::round(v*p)/p; }
inline string DoubleToString(double v,int d=8) { char b[64]; snprintf(b,sizeof b,"%.*f",d,v); return string(b); }
inline string IntegerToString(long long v) { return string(std::to_string(v)); }
inline long long StringToInteger(const string &s) { return atoll(s.utf8().c_str()); }
inline int StringLen(const string &s) { return (int)s.s.size(); }
inline ushort StringGetCharacter(const string &s,int i) { return (i>=0 && i<(int)s.s.size()) ? (ushort)s.s[i] : 0; }
inline string StringSubstr(const string &s,int pos,int len=-1)
  {
   string r; if(pos<0) pos=0; if(pos>=(int)s.s.size()) return r;
   r.s=(len<0) ? s.s.substr(pos) : s.s.substr(pos,(size_t)len); return r;
  }
inline int StringFind(const string &s,const string &sub,int start=0)
  {
   size_t p=s.s.find(sub.s,(size_t)(start<0?0:start)); return (p==std::u32string::npos) ? -1 : (int)p;
  }
inline int StringReplace(string &s,const string &a,const string &b)
  {
   int n=0; size_t p=0;
   while(!a.s.empty() && (p=s.s.find(a.s,p))!=std::u32string::npos) { s.s.replace(p,a.s.size(),b.s); p+=b.s.size(); n++; }
   return n;
  }
inline int StringTrimLeft(string &s) { size_t k=0; while(k<s.s.size() && (s.s[k]==' '||s.s[k]=='\t'||s.s[k]=='\n'||s.s[k]=='\r')) k++; s.s.erase(0,k); return (int)k; }
inline int StringTrimRight(string &s) { size_t n=s.s.size(); while(n>0 && (s.s[n-1]==' '||s.s[n-1]=='\t'||s.s[n-1]=='\n'||s.s[n-1]=='\r')) n--; int r=(int)(s.s.size()-n); s.s.resize(n); return r; }
inline int StringSplit(const string &s,ushort sep,DynArr<string> &out)
  {
   out.v.clear(); if(s.s.empty()) return 0;
   string cur;
   for(char32_t c:s.s) { if(c==(char32_t)sep) { out.v.push_back(cur); cur=string(); } else cur.s.push_back(c); }
   out.v.push_back(cur); return (int)out.v.size();
  }
inline string ShortToString(ushort c) { string r; r.s.push_back(c); return r; }
template<typename T> inline T fmtArg(T v) { return v; }
struct FmtHold { std::string s; };
inline const char *fmtConv(const string &v,std::vector<std::string> &keep) { keep.push_back(v.utf8()); return keep.back().c_str(); }
template<typename T> inline T fmtConv(T v,std::vector<std::string> &) { return v; }
template<typename... A> string StringFormat(const string &f,A... a)
  {
   std::vector<std::string> keep; keep.reserve(16);
   char b[1024]; snprintf(b,sizeof b,f.utf8().c_str(),fmtConv(a,keep)...); return string(b);
  }

//==================== 输出 ====================
inline void Print(const string &m) { SIMG.logs.push_back(m.utf8()); }
inline void Alert(const string &m) { SIMG.alerts.push_back(m.utf8()); SIMG.logs.push_back("[ALERT] "+m.utf8()); }
inline void Comment(const string &) {}
inline int  FileOpen(const string &,int) { return INVALID_HANDLE; }
inline long FileSize(int) { return 0; }
inline void FileWriteString(int,const string &) {}
inline void FileSeek(int,long,int) {}
inline void FileClose(int) {}
inline int  GetLastError() { return SIMG.lastError; }
inline void ResetLastError() { SIMG.lastError=0; }

//==================== 终端全局变量 ====================
inline bool GlobalVariableCheck(const string &n) { return SIMG.gv.count(n.utf8())>0; }
inline double GlobalVariableGet(const string &n) { auto it=SIMG.gv.find(n.utf8()); return it==SIMG.gv.end() ? 0.0 : it->second; }
inline datetime GlobalVariableSet(const string &n,double v)
  {
   if(SIMG.gvWriteFail && n.utf8().rfind("SCE_",0)==0) { SIMG.lastError=4501; return 0; }
   SIMG.gv[n.utf8()]=v; return SIMG.utc();
  }
inline bool GlobalVariableTemp(const string &n) { if(!SIMG.gv.count(n.utf8())) SIMG.gv[n.utf8()]=0; return true; }
inline bool GlobalVariableDel(const string &n) { return SIMG.gv.erase(n.utf8())>0; }
inline void GlobalVariablesFlush() {}
inline int  GlobalVariablesTotal() { return (int)SIMG.gv.size(); }
inline string GlobalVariableName(int k) { auto it=SIMG.gv.begin(); std::advance(it,k); return string(it->first); }

//==================== 品种 / 账户 ====================
inline SimSymbol *SS(const string &s) { auto it=SIMG.sym.find(s.utf8()); return it==SIMG.sym.end() ? nullptr : &it->second; }
inline bool SymbolExist(const string &s,bool &custom) { custom=false; return SS(s)!=nullptr; }
inline bool SymbolSelect(const string &s,bool) { return SS(s)!=nullptr; }
inline double SymbolInfoDouble(const string &s,int p)
  {
   SimSymbol *y=SS(s); if(!y) return 0;
   switch(p)
     {
      case SYMBOL_POINT: return y->point;
      case SYMBOL_TRADE_TICK_SIZE: return y->tickSize;
      case SYMBOL_TRADE_TICK_VALUE: return y->tvWin;
      case SYMBOL_VOLUME_MIN: return y->vmin;
      case SYMBOL_VOLUME_MAX: return y->vmax;
      case SYMBOL_VOLUME_STEP: return y->vstep;
     }
   return 0;
  }
inline bool SymbolInfoDouble(const string &s,int p,double &v) { if(!SS(s)) return false; v=SymbolInfoDouble(s,p); return true; }
inline long SymbolInfoInteger(const string &s,int p)
  {
   SimSymbol *y=SS(s); if(!y) return 0;
   switch(p)
     {
      case SYMBOL_DIGITS: return y->digits;
      case SYMBOL_TRADE_STOPS_LEVEL: return y->stopsLevel;
      case SYMBOL_TRADE_FREEZE_LEVEL: return y->freezeLevel;
      case SYMBOL_FILLING_MODE: return SYMBOL_FILLING_FOK;
      case SYMBOL_TRADE_MODE: return y->tradeMode;
     }
   return 0;
  }
inline bool SymbolInfoTick(const string &s,MqlTick &t)
  {
   SIMG.tickCalls++;
   if(SIMG.onTick) SIMG.onTick(SIMG.tickCalls);
   SimSymbol *y=SS(s); if(!y || !y->hasTick) return false;
   t.bid=y->bid; t.ask=y->ask; t.time=TimeTradeServer()-y->tickAgeSec; return true;
  }
inline bool SymbolInfoSessionTrade(const string &s,ENUM_DAY_OF_WEEK d,uint idx,datetime &from,datetime &to)
  {
   SimSymbol *y=SS(s); if(!y || idx>0) return false;
   if(!y->allDays && (d==SUNDAY || d==SATURDAY)) return false;
   from=y->sessFrom; to=y->sessTo; return true;
  }
inline long AccountInfoInteger(int p)
  {
   switch(p)
     {
      case ACCOUNT_MARGIN_MODE: return SIMG.hedging ? ACCOUNT_MARGIN_MODE_RETAIL_HEDGING : ACCOUNT_MARGIN_MODE_RETAIL_NETTING;
      case ACCOUNT_TRADE_MODE: return SIMG.demo ? ACCOUNT_TRADE_MODE_DEMO : ACCOUNT_TRADE_MODE_REAL;
      case ACCOUNT_TRADE_ALLOWED: return SIMG.accTrade;
      case ACCOUNT_TRADE_EXPERT: return SIMG.accExpert;
      case ACCOUNT_LOGIN: return 12345678;
     }
   return 0;
  }
inline double AccountInfoDouble(int p) { return (p==ACCOUNT_MARGIN_FREE) ? SIMG.freeMargin : 0; }
inline string AccountInfoString(int) { return string("USD"); }
inline long TerminalInfoInteger(int p) { return (p==TERMINAL_CONNECTED) ? SIMG.connected : (p==TERMINAL_TRADE_ALLOWED ? SIMG.termTrade : 0); }
inline long MQLInfoInteger(int p) { return (p==MQL_TRADE_ALLOWED) ? SIMG.mqlTrade : 0; }

//==================== 盈亏 / 保证金 / 预检 ====================
inline bool OrderCalcProfit(ENUM_ORDER_TYPE type,const string &s,double vol,double po,double pc,double &profit)
  {
   SimSymbol *y=SS(s); if(!y || SIMG.failCalcProfit) { SIMG.lastError=4756; return false; }
   double diff=(type==ORDER_TYPE_BUY) ? pc-po : po-pc;
   double ticks=diff/y->tickSize;
   profit=std::round(ticks*vol*(diff>=0 ? y->tvWin : y->tvLoss)*100.0)/100.0;
   return true;
  }
inline bool OrderCalcMargin(ENUM_ORDER_TYPE,const string &s,double vol,double price,double &m) { if(!SS(s)) return false; m=price*vol/100.0; return true; }
inline bool OrderCheck(MqlTradeRequest &,MqlTradeCheckResult &cr) { cr.retcode=0; return true; }

//==================== 持仓 / 订单 / 历史 ====================
inline int PositionsTotal() { return (int)SIMG.pos.size(); }
inline ulong PositionGetTicket(int k) { if(k<0 || k>=(int)SIMG.pos.size()) return 0; SIMG.selPos=k; return SIMG.pos[k].ticket; }
inline bool PositionSelectByTicket(ulong t)
  {
   for(size_t k=0;k<SIMG.pos.size();k++) if(SIMG.pos[k].ticket==t) { SIMG.selPos=(int)k; return true; }
   SIMG.lastError=ERR_TRADE_POSITION_NOT_FOUND; return false;
  }
inline string PositionGetString(int) { return SIMG.pos.at(SIMG.selPos).sym; }
inline long PositionGetInteger(int p)
  {
   SimPos &x=SIMG.pos.at(SIMG.selPos);
   return (p==POSITION_MAGIC) ? x.magic : (p==POSITION_IDENTIFIER) ? x.id : (p==POSITION_TYPE) ? x.type : 0;
  }
inline double PositionGetDouble(int p)
  {
   SimPos &x=SIMG.pos.at(SIMG.selPos);
   return (p==POSITION_VOLUME) ? x.vol : (p==POSITION_SL) ? x.sl : (p==POSITION_TP) ? x.tp : (p==POSITION_PRICE_OPEN) ? x.open : 0;
  }
inline int OrdersTotal() { return 0; }
inline ulong OrderGetTicket(int) { return 0; }
inline string OrderGetString(int) { return string(); }
inline long OrderGetInteger(int) { return 0; }
inline bool HistorySelect(datetime from,datetime to)
  {
   SIMG.sel.clear(); for(auto &d:SIMG.deals) if(d.time>=from && d.time<=to) SIMG.sel.push_back(&d); return true;
  }
inline bool HistorySelectByPosition(long id) { SIMG.sel.clear(); for(auto &d:SIMG.deals) if(d.posId==id) SIMG.sel.push_back(&d); return true; }
inline int HistoryDealsTotal() { return (int)SIMG.sel.size(); }
inline ulong HistoryDealGetTicket(int k) { return SIMG.sel.at(k)->ticket; }
inline SimDeal *DD(ulong t) { for(auto &d:SIMG.deals) if(d.ticket==t) return &d; return nullptr; }
inline string HistoryDealGetString(ulong t,int) { return DD(t)->sym; }
inline long HistoryDealGetInteger(ulong t,int p)
  {
   SimDeal *d=DD(t);
   return (p==DEAL_MAGIC) ? d->magic : (p==DEAL_ENTRY) ? d->entry : (p==DEAL_TIME) ? (long)d->time : (p==DEAL_ORDER) ? (long)d->order : (p==DEAL_REASON) ? d->reason : 0;
  }
inline double HistoryDealGetDouble(ulong t,int) { return DD(t)->vol; }

//==================== CTrade ====================
class CTrade
  {
   ulong magic=0; uint rc=0; ulong rOrder=0,rDeal=0; double rPrice=0,rVol=0;
   bool open(int type,double vol,const string &sym,double sl,double tp)
     {
      rc=0; rOrder=0; rDeal=0; rPrice=0; rVol=0;
      SimSymbol *y=SS(sym);
      SimOrderRec rec{"OPEN",sym,type,vol,0,sl,tp,0};
      if(SIMG.rejectRetcode) { rc=SIMG.rejectRetcode; rec.retcode=rc; SIMG.orders.push_back(rec); return false; }
      bool buy=(type==ORDER_TYPE_BUY);
      bool stopsOk=buy ? (sl<y->bid && tp>y->bid) : (sl>y->ask && tp<y->ask);
      if(!stopsOk) { rc=TRADE_RETCODE_INVALID_STOPS; rec.retcode=rc; SIMG.orders.push_back(rec); return false; }
      double px=buy ? y->ask+SIMG.slip : y->bid-SIMG.slip;
      SimPos p; p.ticket=SIMG.nextTicket++; p.id=(long)p.ticket; p.sym=sym; p.magic=(long)magic; p.type=buy ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
      p.vol=vol; p.open=px; p.sl=SIMG.stripStops ? 0 : sl; p.tp=SIMG.stripStops ? 0 : tp;
      SIMG.pos.push_back(p);
      SimDeal d{SIMG.nextTicket++,sym,(long)magic,DEAL_ENTRY_IN,TimeTradeServer(),vol,p.ticket,DEAL_REASON_EXPERT,p.id};
      SIMG.deals.push_back(d);
      rc=TRADE_RETCODE_DONE; rOrder=p.ticket; rDeal=d.ticket; rPrice=px; rVol=vol;
      rec.price=px; rec.retcode=rc; SIMG.orders.push_back(rec); return true;
     }
public:
   void SetExpertMagicNumber(ulong m) { magic=m; }
   void SetDeviationInPoints(ulong) {}
   void SetAsyncMode(bool) {}
   void SetMarginMode() {}
   void LogLevel(int) {}
   void SetTypeFilling(ENUM_ORDER_TYPE_FILLING) {}
   bool Buy(double vol,const string &sym,double,double sl,double tp,const string &) { return open(ORDER_TYPE_BUY,vol,sym,sl,tp); }
   bool Sell(double vol,const string &sym,double,double sl,double tp,const string &) { return open(ORDER_TYPE_SELL,vol,sym,sl,tp); }
   bool PositionModify(ulong t,double sl,double tp)
     {
      SimOrderRec rec{"MODIFY",string(),0,0,0,sl,tp,0};
      for(auto &p:SIMG.pos) if(p.ticket==t)
        {
         rec.sym=p.sym;
         if(SIMG.failModify) { rc=TRADE_RETCODE_INVALID_STOPS; rec.retcode=rc; SIMG.orders.push_back(rec); return false; }
         p.sl=sl; p.tp=tp; rc=TRADE_RETCODE_DONE; rec.retcode=rc; SIMG.orders.push_back(rec); return true;
        }
      rc=TRADE_RETCODE_ERROR; return false;
     }
   bool PositionClose(ulong t,ulong)
     {
      for(size_t k=0;k<SIMG.pos.size();k++) if(SIMG.pos[k].ticket==t)
        {
         SimPos p=SIMG.pos[k]; SIMG.pos.erase(SIMG.pos.begin()+k);
         ulong ord=SIMG.nextTicket++;
         SIMG.deals.push_back(SimDeal{SIMG.nextTicket++,p.sym,(long)magic,DEAL_ENTRY_OUT,TimeTradeServer(),p.vol,ord,DEAL_REASON_EXPERT,p.id});
         SIMG.orders.push_back(SimOrderRec{"CLOSE",p.sym,0,p.vol,0,0,0,(uint)TRADE_RETCODE_DONE});
         rc=TRADE_RETCODE_DONE; rOrder=ord; rVol=p.vol; return true;
        }
      rc=TRADE_RETCODE_ERROR; return false;
     }
   uint ResultRetcode() { return rc; }
   string ResultRetcodeDescription() { return string("sim"); }
   ulong ResultOrder() { return rOrder; }
   ulong ResultDeal() { return rDeal; }
   double ResultPrice() { return rPrice; }
   double ResultVolume() { return rVol; }
  };

//==================== 图表对象 ====================
inline int  ObjectFind(long,const string &n) { return SIMG.objText.count(n.utf8()) ? 0 : -1; }
inline bool ObjectCreate(long,const string &n,int,int,datetime,double) { SIMG.objText[n.utf8()]=""; return true; }
inline bool ObjectSetInteger(long,const string &,int,long) { return true; }
inline bool ObjectSetString(long,const string &n,int p,const string &v) { if(p==OBJPROP_TEXT) SIMG.objText[n.utf8()]=v.utf8(); return true; }
inline long ObjectGetInteger(long,const string &,int) { return -1; }
inline string ObjectGetString(long,const string &n,int) { return string(SIMG.objText[n.utf8()]); }
inline bool ObjectDelete(long,const string &n) { return SIMG.objText.erase(n.utf8())>0; }
inline int  ObjectsDeleteAll(long,const string &pre)
  {
   int n=0; std::string p=pre.utf8();
   for(auto it=SIMG.objText.begin();it!=SIMG.objText.end();) { if(it->first.rfind(p,0)==0) { it=SIMG.objText.erase(it); n++; } else ++it; }
   return n;
  }
inline long ChartGetInteger(long,int) { return 0xFFFFFF; }
inline void ChartRedraw(long) {}
inline bool TextSetFont(const string &,int) { return true; }
inline bool TextGetSize(const string &s,uint &w,uint &h) { w=0; for(char32_t c:s.s) w+=(c<128) ? 9 : 16; h=18; return true; }
inline bool EventSetTimer(int) { return true; }
inline void EventKillTimer() {}

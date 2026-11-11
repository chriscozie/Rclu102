//+------------------------------------------------------------------+
//|                                                    SwarmHFT.mq5  |
//|   Swarm tick-scalper for Exness MT5 (Raw Spread / Zero accounts) |
//|                                                                  |
//|   5 independent tick/M1 agents vote. Votes are weighted by each  |
//|   agent's learned track record (multiplicative weights update on |
//|   every closed trade). A trade fires only when weighted consensus |
//|   and head-count agreement clear thresholds AND the expected      |
//|   target clears trading cost (spread + commission) by a margin.   |
//+------------------------------------------------------------------+
#property copyright "InfraMEP Systems Ltd"
#property version   "2.00"
#property description "SwarmHFT v2 - swarm-consensus tick scalper for Exness MT5."
#property description "Use on Raw Spread or Zero accounts. Backtest on real ticks before live."

#include <Trade/Trade.mqh>

#define N_AGENTS 5
#define MAX_RECS 128

//==================================================================== INPUTS
input group "=== Identity ==="
input long   InpMagic              = 260111;     // Magic number
input string InpTag                = "SwarmHFT"; // Order comment / GV prefix

input group "=== Risk ==="
input double InpRiskPct            = 0.25;  // Risk per trade, % of equity
input double InpMinLotRiskCapPct   = 1.00;  // If min lot exceeds risk, allow only if risk <= this %
input double InpMaxLot             = 5.00;  // Absolute lot cap
input int    InpMaxPositions       = 2;     // Max open positions (this symbol+magic)
input double InpDailyLossPct       = 2.0;   // Daily loss stop, % of day-start equity (0=off)
input double InpDailyTargetPct     = 3.0;   // Daily profit lock, % (0=off)
input double InpMaxDDPct           = 8.0;   // Peak-equity kill switch, % (0=off)
input bool   InpResetKill          = false; // true = clear kill switch + peak on load
input int    InpMaxConsecLoss      = 4;     // Consecutive losses before cooldown
input int    InpCooldownMin        = 30;    // Cooldown minutes
input int    InpMaxTradesPerHour   = 20;    // Throttle
input int    InpMinSecBetween      = 20;    // Min seconds between entries

input group "=== Cost & execution ==="
input double InpCommissionPerLot   = 7.0;   // Round-turn commission per 1.00 lot, acct ccy (Raw=7, Zero~varies, Standard=0)
input double InpMinEdgeCostMult    = 3.0;   // TP distance must be >= this x (spread+commission)
input double InpMaxSpreadATRFrac   = 0.12;  // Spread must be <= this x ATR(M1)
input int    InpMaxSpreadPts       = 0;     // Absolute spread cap in points (0=off) - set per symbol
input int    InpSlippagePts        = 10;    // Deviation (points)

input group "=== Exits ==="
input int    InpATRPeriod          = 14;    // ATR period (M1)
input double InpSL_ATR             = 0.90;  // Stop loss = x ATR(M1)
input double InpTP_ATR             = 0.80;  // Take profit = x ATR(M1)
input double InpBE_TriggerR        = 0.50;  // Move SL to BE+costs at this R
input double InpTrailStartR        = 0.70;  // Start trailing at this R
input double InpTrailATR           = 0.35;  // Trail distance = x ATR(M1)
input int    InpMaxHoldSec         = 300;   // Time stop (seconds)
input bool   InpCloseOnReverse     = true;  // Close on strong opposite consensus

input group "=== Regime ==="
input double InpMinATRPts          = 0;     // Min ATR(M1) in points (0=off)
input double InpMaxATRPts          = 0;     // Max ATR(M1) in points (0=off) - avoid spikes

input group "=== Swarm ==="
input int    InpTickBuf            = 400;   // Tick ring buffer size
input double InpConsensus          = 0.55;  // |weighted vote| threshold (0..1)
input int    InpMinAgree           = 3;     // Min agents agreeing with direction
input double InpLearnRate          = 0.10;  // Weight learning rate
input double InpWeightDecay        = 0.01;  // Pull weights back toward 1.0 per trade
input double InpWMin               = 0.20;  // Min agent weight
input double InpWMax               = 3.00;  // Max agent weight
input bool   InpPersistWeights     = true;  // Save weights between restarts (live only)

input group "=== Agent 1: Tick momentum ==="
input bool   A1_On                 = true;
input int    A1_Ticks              = 30;    // Lookback ticks
input double A1_MoveSpreadMult     = 2.5;   // Net move must exceed x spread
input double A1_DirRatio           = 0.62;  // Share of ticks in direction

input group "=== Agent 2: Quote pressure burst ==="
input bool   A2_On                 = true;
input int    A2_Ticks              = 60;    // Lookback ticks
input double A2_Imbalance          = 0.30;  // |pressure| threshold (0..1)
input int    A2_MaxSec             = 20;    // Those ticks must occur within N s (burst)

input group "=== Agent 3: Micro mean-reversion (contrarian) ==="
input bool   A3_On                 = true;
input int    A3_EmaTicks           = 120;   // EW mean length (ticks)
input double A3_Z                  = 2.2;   // Fade when |z| > this

input group "=== Agent 4: N-second range breakout ==="
input bool   A4_On                 = true;
input int    A4_Seconds            = 60;    // Range window (s)
input double A4_BreakSpreadMult    = 1.0;   // Break buffer = x spread

input group "=== Agent 5: M1 trend bias ==="
input bool   A5_On                 = true;
input int    A5_Fast               = 9;     // EMA fast (M1)
input int    A5_Slow               = 34;    // EMA slow (M1)

input group "=== Session (broker server time; Exness = GMT+0) ==="
input int    InpStartHour          = 7;     // Trade from (hour)
input int    InpEndHour            = 20;    // Trade until (hour)
input int    InpBlockFromHHMM      = 2050;  // Rollover blackout start HHMM
input int    InpBlockToHHMM        = 2215;  // Rollover blackout end HHMM
input int    InpFridayStopHour     = 19;    // No new trades Friday from
input int    InpMondayStartHour    = 8;     // No new trades Monday before

input group "=== News (live only, MT5 economic calendar) ==="
input bool   InpNewsFilter         = true;
input int    InpNewsMinsBefore     = 15;
input int    InpNewsMinsAfter      = 15;

input group "=== Display ==="
input bool   InpShowPanel          = true;

//=================================================================== GLOBALS
CTrade   trade;

double   gBid[], gAsk[];
long     gMsc[];
int      gHead = 0, gCount = 0;

double   gEma = 0, gVar = 0;
int      gEmaN = 0;

double   gW[N_AGENTS];
int      gVote[N_AGENTS];
bool     gOn[N_AGENTS];
string   gName[N_AGENTS] = {"Momentum","Pressure","MeanRev","Breakout","Trend"};

int      hATR = INVALID_HANDLE, hFast = INVALID_HANDLE, hSlow = INVALID_HANDLE;

struct TradeRec
  {
   bool     used;
   ulong    pos;
   int      dir;
   int      votes[N_AGENTS];
   double   risk;      // money at risk incl. commission
   double   slPts;     // initial SL distance (points)
   double   costPts;   // spread+commission at entry (points)
  };
TradeRec gRec[MAX_RECS];

datetime gDay = 0;
double   gDayStartEq = 0, gPeakEq = 0;
bool     gHaltDay = false, gKill = false;
int      gConsecLoss = 0;
datetime gCooldownUntil = 0;
datetime gLastEntry = 0;
long     gHourKey = -1;
int      gHourTrades = 0;
int      gWins = 0, gLosses = 0;
double   gNet = 0;
double   gLastS = 0;
int      gLastAgree = 0;
string   gBlock = "";
uint     gLastPanel = 0;
bool     gTester = false;

//=================================================================== HELPERS
string GV(const string k) { return InpTag + "_" + _Symbol + "_" + IntegerToString(InpMagic) + "_" + k; }

int Idx(const int back) { return (gHead - 1 - back + 2 * InpTickBuf) % InpTickBuf; }
double Mid(const int back) { int i = Idx(back); return 0.5 * (gBid[i] + gAsk[i]); }

double Clamp(const double v, const double lo, const double hi) { return MathMax(lo, MathMin(hi, v)); }

double NormPrice(const double p)
  {
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(ts <= 0) return NormalizeDouble(p, _Digits);
   return NormalizeDouble(MathRound(p / ts) * ts, _Digits);
  }

// Money per 1 point move for 1.00 lot
double PointValuePerLot()
  {
   double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(ts <= 0 || tv <= 0) return 0;
   return tv * _Point / ts;
  }

double ATRPrice()
  {
   double a[1];
   if(CopyBuffer(hATR, 0, 1, 1, a) != 1) return 0;
   return a[0];
  }

double NormLots(double lots, const double lossPerLot)
  {
   double mn = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double mx = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double st = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(st <= 0) st = 0.01;
   lots = MathFloor(lots / st + 1e-9) * st;
   if(lots < mn)
     {
      // allow min lot only if its risk is within the cap
      double eq = AccountInfoDouble(ACCOUNT_EQUITY);
      if(mn * lossPerLot <= eq * InpMinLotRiskCapPct / 100.0) lots = mn;
      else return 0;
     }
   lots = MathMin(lots, MathMin(mx, InpMaxLot));
   int dg = (int)MathMax(0, MathCeil(-MathLog10(st) - 1e-9));
   return NormalizeDouble(lots, dg);
  }

int CountPos(const int dir) // dir: 0=all, 1=buy, -1=sell
  {
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0 || !PositionSelectByTicket(tk)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      long t = PositionGetInteger(POSITION_TYPE);
      if(dir == 0 || (dir == 1 && t == POSITION_TYPE_BUY) || (dir == -1 && t == POSITION_TYPE_SELL)) n++;
     }
   return n;
  }

void CloseDir(const int dir) // 0=all
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0 || !PositionSelectByTicket(tk)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      long t = PositionGetInteger(POSITION_TYPE);
      if(dir == 0 || (dir == 1 && t == POSITION_TYPE_BUY) || (dir == -1 && t == POSITION_TYPE_SELL))
         trade.PositionClose(tk, InpSlippagePts);
     }
  }

int FindRec(const ulong pos)
  {
   for(int i = 0; i < MAX_RECS; i++) if(gRec[i].used && gRec[i].pos == pos) return i;
   return -1;
  }

int FreeRec()
  {
   for(int i = 0; i < MAX_RECS; i++) if(!gRec[i].used) return i;
   return -1;
  }

//=========================================================== PERSISTENCE
void LoadState()
  {
   for(int a = 0; a < N_AGENTS; a++) gW[a] = 1.0;
   gPeakEq = AccountInfoDouble(ACCOUNT_EQUITY);
   gKill = false;
   if(gTester) return;

   if(InpResetKill)
     {
      GlobalVariableDel(GV("kill"));
      GlobalVariableDel(GV("peak"));
     }
   if(InpPersistWeights)
      for(int a = 0; a < N_AGENTS; a++)
         if(GlobalVariableCheck(GV("w" + IntegerToString(a))))
            gW[a] = Clamp(GlobalVariableGet(GV("w" + IntegerToString(a))), InpWMin, InpWMax);
   if(GlobalVariableCheck(GV("peak"))) gPeakEq = MathMax(gPeakEq, GlobalVariableGet(GV("peak")));
   if(GlobalVariableCheck(GV("kill"))) gKill = (GlobalVariableGet(GV("kill")) > 0.5);
  }

void SaveWeights()
  {
   if(gTester || !InpPersistWeights) return;
   for(int a = 0; a < N_AGENTS; a++) GlobalVariableSet(GV("w" + IntegerToString(a)), gW[a]);
  }

//================================================================ TICKS
void PushTick(const MqlTick &t)
  {
   gBid[gHead] = t.bid;
   gAsk[gHead] = t.ask;
   gMsc[gHead] = t.time_msc;
   gHead = (gHead + 1) % InpTickBuf;
   if(gCount < InpTickBuf) gCount++;

   double mid = 0.5 * (t.bid + t.ask);
   double al = 2.0 / (A3_EmaTicks + 1.0);
   if(gEmaN == 0) { gEma = mid; gVar = 0; }
   else
     {
      double d = mid - gEma;
      gEma += al * d;
      gVar = (1.0 - al) * (gVar + al * d * d);
     }
   gEmaN++;
  }

//================================================================ AGENTS
// A1: net tick momentum with directional persistence
int AgentMomentum(const double spread)
  {
   int K = A1_Ticks;
   if(K < 2 || gCount <= K) return 0;
   double move = Mid(0) - Mid(K);
   int up = 0, dn = 0;
   for(int b = 0; b < K; b++)
     {
      double d = Mid(b) - Mid(b + 1);
      if(d > 0) up++; else if(d < 0) dn++;
     }
   int tot = up + dn;
   if(tot == 0) return 0;
   double r = (double)up / tot;
   if(move >  A1_MoveSpreadMult * spread && r >= A1_DirRatio)         return  1;
   if(move < -A1_MoveSpreadMult * spread && (1.0 - r) >= A1_DirRatio) return -1;
   return 0;
  }

// A2: quote pressure (ask lifts / bid hits) during a tick burst
int AgentPressure()
  {
   int W = A2_Ticks;
   if(W < 2 || gCount <= W) return 0;
   long span = gMsc[Idx(0)] - gMsc[Idx(W)];
   if(span > (long)A2_MaxSec * 1000) return 0;          // no burst -> abstain
   double s = 0;
   for(int b = 0; b < W; b++)
     {
      int i = Idx(b), j = Idx(b + 1);
      double da = gAsk[i] - gAsk[j], db = gBid[i] - gBid[j];
      s += (da > 0 ? 1 : (da < 0 ? -1 : 0));
      s += (db > 0 ? 1 : (db < 0 ? -1 : 0));
     }
   double imb = s / (2.0 * W);
   if(imb >=  A2_Imbalance) return  1;
   if(imb <= -A2_Imbalance) return -1;
   return 0;
  }

// A3: contrarian fade of stretched price vs EW mean
int AgentMeanRev(const double spread)
  {
   if(gEmaN < A3_EmaTicks) return 0;
   double sd = MathSqrt(gVar);
   if(sd <= 0.25 * spread || sd <= 0) return 0;
   double z = (Mid(0) - gEma) / sd;
   if(z >  A3_Z) return -1;
   if(z < -A3_Z) return  1;
   return 0;
  }

// A4: break of the last N-second range
int AgentBreakout(const double spread)
  {
   if(gCount < 20) return 0;
   long from = gMsc[Idx(0)] - (long)A4_Seconds * 1000;
   double hi = -DBL_MAX, lo = DBL_MAX;
   int n = 0;
   for(int b = 1; b < gCount; b++)
     {
      int i = Idx(b);
      if(gMsc[i] < from) break;
      double m = 0.5 * (gBid[i] + gAsk[i]);
      if(m > hi) hi = m;
      if(m < lo) lo = m;
      n++;
     }
   if(n < 10) return 0;
   double m0 = Mid(0);
   if(m0 > hi + A4_BreakSpreadMult * spread) return  1;
   if(m0 < lo - A4_BreakSpreadMult * spread) return -1;
   return 0;
  }

// A5: closed-bar M1 EMA alignment + slope
int AgentTrend()
  {
   double f[2], s[2];
   if(CopyBuffer(hFast, 0, 1, 2, f) != 2 || CopyBuffer(hSlow, 0, 1, 2, s) != 2) return 0;
   double c = iClose(_Symbol, PERIOD_M1, 1);
   // non-series: [0]=older (shift 2), [1]=newer (shift 1)
   if(f[1] > s[1] && f[1] > f[0] && c > f[1]) return  1;
   if(f[1] < s[1] && f[1] < f[0] && c < f[1]) return -1;
   return 0;
  }

void Vote(const double spread)
  {
   gVote[0] = gOn[0] ? AgentMomentum(spread) : 0;
   gVote[1] = gOn[1] ? AgentPressure()       : 0;
   gVote[2] = gOn[2] ? AgentMeanRev(spread)  : 0;
   gVote[3] = gOn[3] ? AgentBreakout(spread) : 0;
   gVote[4] = gOn[4] ? AgentTrend()          : 0;
  }

// Weighted consensus over ACTIVE agents (abstainers dilute the score)
double Consensus(int &agree)
  {
   double num = 0, den = 0;
   for(int a = 0; a < N_AGENTS; a++)
     {
      if(!gOn[a]) continue;
      num += gW[a] * gVote[a];
      den += gW[a];
     }
   double S = (den > 0 ? num / den : 0);
   int sg = (S > 0 ? 1 : (S < 0 ? -1 : 0));
   agree = 0;
   if(sg != 0) for(int a = 0; a < N_AGENTS; a++) if(gOn[a] && gVote[a] == sg) agree++;
   return S;
  }

//================================================================ FILTERS
bool InSession()
  {
   MqlDateTime d;
   TimeToStruct(TimeCurrent(), d);
   if(d.day_of_week == 0 || d.day_of_week == 6) return false;
   int m  = d.hour * 60 + d.min;
   if(m < InpStartHour * 60 || m >= InpEndHour * 60) return false;
   int b0 = (InpBlockFromHHMM / 100) * 60 + InpBlockFromHHMM % 100;
   int b1 = (InpBlockToHHMM   / 100) * 60 + InpBlockToHHMM   % 100;
   if(b0 < b1 && m >= b0 && m < b1) return false;
   if(b0 > b1 && (m >= b0 || m < b1)) return false;
   if(d.day_of_week == 5 && d.hour >= InpFridayStopHour) return false;
   if(d.day_of_week == 1 && d.hour <  InpMondayStartHour) return false;
   return true;
  }

bool NewsBlackout()
  {
   if(!InpNewsFilter || gTester) return false;
   static datetime lastCheck = 0;
   static bool cached = false;
   datetime now = TimeTradeServer();
   if(now - lastCheck < 60) return cached;
   lastCheck = now;
   cached = false;
   string ccy[2];
   ccy[0] = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_BASE);
   ccy[1] = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_PROFIT);
   datetime from = now - InpNewsMinsAfter * 60, to = now + InpNewsMinsBefore * 60;
   for(int c = 0; c < 2 && !cached; c++)
     {
      if(c == 1 && ccy[1] == ccy[0]) break;
      MqlCalendarValue v[];
      if(CalendarValueHistory(v, from, to, NULL, ccy[c]) <= 0) continue;
      for(int i = 0; i < ArraySize(v); i++)
        {
         MqlCalendarEvent ev;
         if(CalendarEventById(v[i].event_id, ev) && ev.importance == CALENDAR_IMPORTANCE_HIGH)
           { cached = true; break; }
        }
     }
   return cached;
  }

void DayRoll()
  {
   datetime now = TimeCurrent();
   datetime day = now - (now % 86400);
   if(day != gDay)
     {
      gDay = day;
      gDayStartEq = AccountInfoDouble(ACCOUNT_EQUITY);
      gHaltDay = false;
      if(!gTester)
        {
         // survive restarts mid-day: keep the true day-start equity
         if(GlobalVariableCheck(GV("day")) && (datetime)GlobalVariableGet(GV("day")) == day && GlobalVariableCheck(GV("dayeq")))
            gDayStartEq = GlobalVariableGet(GV("dayeq"));
         else
           {
            GlobalVariableSet(GV("day"), (double)day);
            GlobalVariableSet(GV("dayeq"), gDayStartEq);
           }
        }
     }
  }

void RiskGuards()
  {
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq > gPeakEq)
     {
      gPeakEq = eq;
      if(!gTester) GlobalVariableSet(GV("peak"), gPeakEq);
     }
   if(!gKill && InpMaxDDPct > 0 && eq <= gPeakEq * (1.0 - InpMaxDDPct / 100.0))
     {
      gKill = true;
      if(!gTester) GlobalVariableSet(GV("kill"), 1.0);
      CloseDir(0);
      Print("SwarmHFT KILL SWITCH: equity ", eq, " <= peak ", gPeakEq, " less ", InpMaxDDPct, "%. Set InpResetKill=true to resume.");
     }
   if(gHaltDay || gDayStartEq <= 0) return;
   double pnl = eq - gDayStartEq;
   if(InpDailyLossPct > 0 && pnl <= -gDayStartEq * InpDailyLossPct / 100.0)
     { gHaltDay = true; CloseDir(0); Print("SwarmHFT daily loss stop hit: ", DoubleToString(pnl, 2)); }
   else if(InpDailyTargetPct > 0 && pnl >= gDayStartEq * InpDailyTargetPct / 100.0)
     { gHaltDay = true; CloseDir(0); Print("SwarmHFT daily target locked: ", DoubleToString(pnl, 2)); }
  }

// Returns "" if entries allowed, else block reason
string EntryBlock(const MqlTick &t, const double atr)
  {
   if(gKill)                                   return "KILL SWITCH";
   if(gHaltDay)                                return "day halted";
   if(TimeCurrent() < gCooldownUntil)          return "loss cooldown";
   if(!InSession())                            return "off session";
   if(NewsBlackout())                          return "news";
   if(atr <= 0)                                return "no ATR";
   double spread = t.ask - t.bid;
   double atrPts = atr / _Point, sprPts = spread / _Point;
   if(InpMaxSpreadPts > 0 && sprPts > InpMaxSpreadPts)  return "spread abs";
   if(spread > InpMaxSpreadATRFrac * atr)               return "spread/ATR";
   if(InpMinATRPts > 0 && atrPts < InpMinATRPts)        return "ATR low";
   if(InpMaxATRPts > 0 && atrPts > InpMaxATRPts)        return "ATR spike";
   if(CountPos(0) >= InpMaxPositions)                   return "max positions";
   if(TimeCurrent() - gLastEntry < InpMinSecBetween)    return "spacing";
   long hk = (long)(TimeCurrent() / 3600);
   if(hk != gHourKey) { gHourKey = hk; gHourTrades = 0; }
   if(gHourTrades >= InpMaxTradesPerHour)               return "hourly cap";
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) && !gTester) return "algo trading off";
   return "";
  }

//================================================================ ENTRY
bool Enter(const int dir, const MqlTick &t, const double atr)
  {
   double pv = PointValuePerLot();
   if(pv <= 0) { gBlock = "no tick value"; return false; }

   double sprPts  = (t.ask - t.bid) / _Point;
   double commPts = InpCommissionPerLot / pv;
   double costPts = sprPts + commPts;

   double stopsPts = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double slPts = MathMax(InpSL_ATR * atr / _Point, stopsPts + sprPts + 1);
   double tpPts = MathMax(InpTP_ATR * atr / _Point, stopsPts + 1);

   if(tpPts < InpMinEdgeCostMult * costPts) { gBlock = "edge<cost"; return false; }

   double eq        = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = eq * InpRiskPct / 100.0;
   double lossPerLot = slPts * pv + InpCommissionPerLot;
   double lots = NormLots(riskMoney / lossPerLot, lossPerLot);
   if(lots <= 0) { gBlock = "lot<min (risk)"; return false; }

   double price = (dir > 0 ? t.ask : t.bid);
   ENUM_ORDER_TYPE ot = (dir > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   double margin = 0;
   if(OrderCalcMargin(ot, _Symbol, lots, price, margin) && margin > AccountInfoDouble(ACCOUNT_MARGIN_FREE) * 0.9)
     { gBlock = "margin"; return false; }

   double sl = NormPrice(dir > 0 ? price - slPts * _Point : price + slPts * _Point);
   double tp = NormPrice(dir > 0 ? price + tpPts * _Point : price - tpPts * _Point);

   bool ok = (dir > 0) ? trade.Buy(lots, _Symbol, price, sl, tp, InpTag)
                       : trade.Sell(lots, _Symbol, price, sl, tp, InpTag);
   uint rc = trade.ResultRetcode();
   if(!ok || (rc != TRADE_RETCODE_DONE && rc != TRADE_RETCODE_PLACED && rc != TRADE_RETCODE_DONE_PARTIAL))
     {
      PrintFormat("SwarmHFT entry failed rc=%u %s", rc, trade.ResultRetcodeDescription());
      gBlock = "send failed";
      return false;
     }

   // Resolve position id (MT5: = opening order ticket; confirm via deal if available)
   ulong pos = trade.ResultOrder();
   ulong deal = trade.ResultDeal();
   if(deal > 0 && HistoryDealSelect(deal))
     {
      ulong p = (ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID);
      if(p > 0) pos = p;
     }
   double filled = trade.ResultVolume() > 0 ? trade.ResultVolume() : lots;

   int k = FreeRec();
   if(k >= 0)
     {
      gRec[k].used    = true;
      gRec[k].pos     = pos;
      gRec[k].dir     = dir;
      for(int a = 0; a < N_AGENTS; a++) gRec[k].votes[a] = gVote[a];
      gRec[k].risk    = filled * lossPerLot;
      gRec[k].slPts   = slPts;
      gRec[k].costPts = costPts;
     }
   gLastEntry = TimeCurrent();
   gHourTrades++;
   return true;
  }

//============================================================ MANAGEMENT
void Manage(const MqlTick &t, const double atr)
  {
   double pv = PointValuePerLot();
   double commPts = (pv > 0 ? InpCommissionPerLot / pv : 0);
   double stopsPts = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double sprPts = (t.ask - t.bid) / _Point;
   double step = MathMax(sprPts, 2.0) * _Point;   // min SL improvement to send a modify

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0 || !PositionSelectByTicket(tk)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;

      bool   buy  = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl   = PositionGetDouble(POSITION_SL);
      double tp   = PositionGetDouble(POSITION_TP);
      datetime ot = (datetime)PositionGetInteger(POSITION_TIME);

      // Time stop
      if(InpMaxHoldSec > 0 && TimeCurrent() - ot >= InpMaxHoldSec)
        { trade.PositionClose(tk, InpSlippagePts); continue; }

      ulong posId = (ulong)PositionGetInteger(POSITION_IDENTIFIER);
      int k = FindRec(posId);
      double slPts0 = (k >= 0 ? gRec[k].slPts : InpSL_ATR * atr / _Point);
      if(slPts0 <= 0) continue;

      double cur  = buy ? t.bid : t.ask;
      double prof = buy ? (cur - open) / _Point : (open - cur) / _Point;
      double R    = prof / slPts0;
      double nsl  = sl;

      if(R >= InpBE_TriggerR)
        {
         double be = buy ? open + (commPts + 2) * _Point : open - (commPts + 2) * _Point;
         if(buy  && (nsl == 0 || be > nsl)) nsl = be;
         if(!buy && (nsl == 0 || be < nsl)) nsl = be;
        }
      if(R >= InpTrailStartR && atr > 0)
        {
         double tr = buy ? cur - InpTrailATR * atr : cur + InpTrailATR * atr;
         if(buy  && tr > nsl) nsl = tr;
         if(!buy && tr < nsl) nsl = tr;
        }
      if(nsl == sl) continue;
      nsl = NormPrice(nsl);

      // Respect broker stop level and require meaningful improvement
      if(buy)
        {
         if(nsl > t.bid - stopsPts * _Point - _Point) continue;
         if(sl != 0 && nsl - sl < step) continue;
        }
      else
        {
         if(nsl < t.ask + stopsPts * _Point + _Point) continue;
         if(sl != 0 && sl - nsl < step) continue;
        }
      trade.PositionModify(tk, nsl, tp);
     }
  }

//============================================================== LEARNING
double PositionNet(const ulong pos)
  {
   if(!HistorySelectByPosition(pos)) return 0;
   double s = 0;
   int n = HistoryDealsTotal();
   for(int i = 0; i < n; i++)
     {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0) continue;
      s += HistoryDealGetDouble(d, DEAL_PROFIT) + HistoryDealGetDouble(d, DEAL_SWAP)
         + HistoryDealGetDouble(d, DEAL_COMMISSION) + HistoryDealGetDouble(d, DEAL_FEE);
     }
   return s;
  }

void OnClosed(const ulong pos, const double net)
  {
   int k = FindRec(pos);
   if(k >= 0)
     {
      double R = (gRec[k].risk > 0 ? net / gRec[k].risk : 0);
      R = Clamp(R, -2.0, 2.0);
      for(int a = 0; a < N_AGENTS; a++)
        {
         if(gRec[k].votes[a] != 0)
           {
            double reward = gRec[k].votes[a] * gRec[k].dir * R;   // + if agent was right
            gW[a] *= MathExp(InpLearnRate * reward);
           }
         gW[a] = 1.0 + (gW[a] - 1.0) * (1.0 - InpWeightDecay);
         gW[a] = Clamp(gW[a], InpWMin, InpWMax);
        }
      gRec[k].used = false;
      SaveWeights();
     }

   gNet += net;
   if(net < 0)
     {
      gLosses++;
      gConsecLoss++;
      if(InpMaxConsecLoss > 0 && gConsecLoss >= InpMaxConsecLoss)
        {
         gCooldownUntil = TimeCurrent() + InpCooldownMin * 60;
         gConsecLoss = 0;
        }
     }
   else
     {
      gWins++;
      gConsecLoss = 0;
     }
  }

void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &req, const MqlTradeResult &res)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if(trans.symbol != _Symbol) return;
   ulong deal = trans.deal;
   if(deal == 0 || !HistoryDealSelect(deal)) return;
   long entry = HistoryDealGetInteger(deal, DEAL_ENTRY);
   if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY) return;
   ulong pos = (ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID);
   long  mg  = HistoryDealGetInteger(deal, DEAL_MAGIC);
   if(FindRec(pos) < 0 && mg != InpMagic) return;
   if(PositionSelectByTicket(pos)) return;   // still open (partial) - wait for final close
   OnClosed(pos, PositionNet(pos));
  }

//================================================================ PANEL
void Panel(const double atr, const MqlTick &t)
  {
   if(!InpShowPanel || (gTester && !MQLInfoInteger(MQL_VISUAL_MODE))) return;
   uint now = GetTickCount();
   if(now - gLastPanel < 500) return;
   gLastPanel = now;
   string s = "SwarmHFT v2  |  " + _Symbol + "\n";
   s += StringFormat("Spread %.0f pts  ATR(M1) %.0f pts  Spr/ATR %.2f\n",
                     (t.ask - t.bid) / _Point, atr / _Point, atr > 0 ? (t.ask - t.bid) / atr : 0);
   for(int a = 0; a < N_AGENTS; a++)
      s += StringFormat("  %-9s w=%.2f  vote=%+d %s\n", gName[a], gW[a], gVote[a], gOn[a] ? "" : "(off)");
   s += StringFormat("Consensus %+.2f  agree %d  (need %.2f / %d)\n", gLastS, gLastAgree, InpConsensus, InpMinAgree);
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   s += StringFormat("Day P/L %.2f  Peak %.2f  Net %.2f  W/L %d/%d\n", eq - gDayStartEq, gPeakEq, gNet, gWins, gLosses);
   s += "Status: " + (gBlock == "" ? "READY" : gBlock);
   Comment(s);
  }

//============================================================ LIFECYCLE
int OnInit()
  {
   gTester = (bool)MQLInfoInteger(MQL_TESTER);

   if(InpTickBuf < 50 || A1_Ticks >= InpTickBuf || A2_Ticks >= InpTickBuf)
     { Print("SwarmHFT: InpTickBuf must be >= 50 and > A1_Ticks/A2_Ticks"); return INIT_PARAMETERS_INCORRECT; }
   if(InpSL_ATR <= 0 || InpTP_ATR <= 0 || InpRiskPct <= 0 || InpMinAgree < 1 || InpMinAgree > N_AGENTS)
     { Print("SwarmHFT: invalid SL/TP/risk/agree inputs"); return INIT_PARAMETERS_INCORRECT; }

   ArrayResize(gBid, InpTickBuf);
   ArrayResize(gAsk, InpTickBuf);
   ArrayResize(gMsc, InpTickBuf);
   ArrayInitialize(gBid, 0);
   ArrayInitialize(gAsk, 0);
   ArrayInitialize(gMsc, 0);

   gOn[0] = A1_On; gOn[1] = A2_On; gOn[2] = A3_On; gOn[3] = A4_On; gOn[4] = A5_On;
   int active = 0;
   for(int a = 0; a < N_AGENTS; a++) { gVote[a] = 0; if(gOn[a]) active++; }
   if(active < InpMinAgree) { Print("SwarmHFT: fewer active agents than InpMinAgree"); return INIT_PARAMETERS_INCORRECT; }
   for(int i = 0; i < MAX_RECS; i++) gRec[i].used = false;

   hATR  = iATR(_Symbol, PERIOD_M1, InpATRPeriod);
   hFast = iMA(_Symbol, PERIOD_M1, A5_Fast, 0, MODE_EMA, PRICE_CLOSE);
   hSlow = iMA(_Symbol, PERIOD_M1, A5_Slow, 0, MODE_EMA, PRICE_CLOSE);
   if(hATR == INVALID_HANDLE || hFast == INVALID_HANDLE || hSlow == INVALID_HANDLE)
     { Print("SwarmHFT: indicator handle failed"); return INIT_FAILED; }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePts);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetAsyncMode(false);

   LoadState();
   gDay = 0;
   DayRoll();

   if(InpCommissionPerLot <= 0)
      Print("SwarmHFT WARNING: commission=0. Correct only for Standard accounts - whose spreads are usually too wide for this EA.");
   if(AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
      Print("SwarmHFT: netting account detected - opposite entries are blocked; reverse = close only.");

   PrintFormat("SwarmHFT v2 ready on %s | digits=%d point=%g tickValue/pt/lot=%.5f stopsLevel=%d",
               _Symbol, _Digits, _Point, PointValuePerLot(), (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL));
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   SaveWeights();
   if(hATR  != INVALID_HANDLE) IndicatorRelease(hATR);
   if(hFast != INVALID_HANDLE) IndicatorRelease(hFast);
   if(hSlow != INVALID_HANDLE) IndicatorRelease(hSlow);
   Comment("");
  }

void OnTick()
  {
   MqlTick t;
   if(!SymbolInfoTick(_Symbol, t) || t.bid <= 0 || t.ask <= 0 || t.ask < t.bid) return;

   PushTick(t);
   DayRoll();
   RiskGuards();

   double atr = ATRPrice();
   Manage(t, atr);

   double spread = t.ask - t.bid;
   Vote(spread);
   gLastS = Consensus(gLastAgree);

   gBlock = EntryBlock(t, atr);
   int dir = (gLastS >= InpConsensus ? 1 : (gLastS <= -InpConsensus ? -1 : 0));

   bool signal = (dir != 0 && gLastAgree >= InpMinAgree);

   // Reverse exit is a risk action: allowed even when entries are blocked
   if(signal && InpCloseOnReverse && CountPos(-dir) > 0)
      CloseDir(-dir);                              // flatten; re-evaluate next tick
   else if(signal && gBlock == "" && CountPos(-dir) == 0)
      Enter(dir, t, atr);
   else if(gBlock == "")
      gBlock = "scanning";

   Panel(atr, t);
  }

//============================================================ OPTIMISER
// Custom criterion: rewards PF, recovery and sample size, penalises DD.
double OnTester()
  {
   double n  = TesterStatistics(STAT_TRADES);
   double np = TesterStatistics(STAT_PROFIT);
   double pf = TesterStatistics(STAT_PROFIT_FACTOR);
   double rf = TesterStatistics(STAT_RECOVERY_FACTOR);
   double dd = TesterStatistics(STAT_EQUITY_DDREL_PERCENT);
   if(n < 200 || np <= 0 || pf < 1.05) return 0;
   return pf * rf * MathSqrt(n) / (1.0 + dd);
  }
//+------------------------------------------------------------------+

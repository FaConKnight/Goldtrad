#ifndef TECHNICALENGINE_MQH
#define TECHNICALENGINE_MQH

#include "Config.mqh"
#include "DataFeed.mqh"
#include <Indicators/Indicators.mqh>

struct Signal { bool isValid; bool isBuy; double sl; double tp; };

namespace tech
{
   // Internal indicator handles
   static int hRSI = INVALID_HANDLE;
   static int hBB  = INVALID_HANDLE;

   bool init_handles()
   {
      if(hRSI == INVALID_HANDLE)
         hRSI = iRSI(EA_SYMBOL, PERIOD_H1, RSI_PERIOD, PRICE_CLOSE);
      if(hBB == INVALID_HANDLE)
         hBB  = iBands(EA_SYMBOL, PERIOD_H1, 20, 2.0, 0, PRICE_CLOSE);
      return (hRSI != INVALID_HANDLE && hBB != INVALID_HANDLE);
   }

   // Price action triggers: Engulfing or Hammer/Shooting Star on H1
   bool is_trigger(bool buy)
   {
      double o = iOpen(EA_SYMBOL, PERIOD_H1, 0);
      double c = iClose(EA_SYMBOL, PERIOD_H1, 0);
      double h = iHigh(EA_SYMBOL, PERIOD_H1, 0);
      double l = iLow(EA_SYMBOL, PERIOD_H1, 0);
      double prev_o = iOpen(EA_SYMBOL, PERIOD_H1, 1);
      double prev_c = iClose(EA_SYMBOL, PERIOD_H1, 1);

      // Engulfing
      bool engulf_buy  = buy && (c > o) && (c > prev_o) && (o < prev_c);
      bool engulf_sell = !buy && (c < o) && (c < prev_o) && (o > prev_c);

      // Hammer/Shooting Star: small body, long wick
      double body   = MathAbs(c - o);
      double candle = h - l;
      bool hammer = buy && (body / candle < 0.3) && ((c - o) > 0) && ((o - l) > 2 * (h - c));
      bool star   = !buy && (body / candle < 0.3) && ((o - c) > 0) && ((h - o) > 2 * (c - l));

      return (buy  && (engulf_buy  || hammer)) ||
             (!buy && (engulf_sell || star));
   }

   // Detect latest Order Block on H1, return mid-price
   double DetectOrderBlock(ENUM_TIMEFRAMES tf)
   {
      int limit = 50; // bars back
      for(int i = 1; i < limit; ++i)
      {
         double o   = iOpen(EA_SYMBOL, tf, i);
         double c   = iClose(EA_SYMBOL, tf, i);
         double body = MathAbs(c - o);
         double atr  = datafeed::ATR(ATR_PERIOD, tf);
         if(body < 0.8 * atr) continue;
         // Bullish OB if candle up, bearish if down
         return (o + c) / 2.0;
      }
      return 0;
   }

   // Stub for Fair Value Gap detection
   bool DetectFVG(ENUM_TIMEFRAMES tf)
   {
      // TODO: implement FVG logic
      // Require at least 3 bars: gap between bar i+1 high and bar i low
      int maxBars = 10;
      double atr = datafeed::ATR(ATR_PERIOD, tf);
      double minGap = atr * 0.2; // threshold
      for(int i = 2; i <= maxBars; ++i)
      {
         double highPrev = iHigh(EA_SYMBOL, tf, i);
         double lowCur  = iLow(EA_SYMBOL, tf, i-1);
         if(lowCur > highPrev + minGap)
            return true;
         double lowPrev = iLow(EA_SYMBOL, tf, i);
         double highCur = iHigh(EA_SYMBOL, tf, i-1);
         if(highCur < lowPrev - minGap)
            return true;
      }
      return false;
   }

   // Stub for Liquidity Zone check
   bool InLiquidityZone()
   {
      int lookback = 150;
      double price = SymbolInfoDouble(EA_SYMBOL, SYMBOL_BID);
      for(int i = 1; i < lookback; ++i)
      {
         // Pivot high
         if(iHigh(EA_SYMBOL, PERIOD_H1, i) > iHigh(EA_SYMBOL, PERIOD_H1, i+1) &&
            iHigh(EA_SYMBOL, PERIOD_H1, i) > iHigh(EA_SYMBOL, PERIOD_H1, i-1))
         {
            if(fabs(price - iHigh(EA_SYMBOL, PERIOD_H1, i)) < _Point * ATR_PERIOD)
               return true;
         }
         // Pivot low
         if(iLow(EA_SYMBOL, PERIOD_H1, i) < iLow(EA_SYMBOL, PERIOD_H1, i+1) &&
            iLow(EA_SYMBOL, PERIOD_H1, i) < iLow(EA_SYMBOL, PERIOD_H1, i-1))
         {
            if(fabs(price - iLow(EA_SYMBOL, PERIOD_H1, i)) < _Point * ATR_PERIOD)
               return true;
         }
      }
      return false;
   }
   
      // Multi-Timeframe confirmation for FVG or OB
   bool ConfirmMultiTF(ENUM_TIMEFRAMES higherTF)
   {
      // E.g., check FVG on higher timeframe
      return DetectFVG(higherTF) || DetectFVG(PERIOD_H4);
   }

   // Main signal generator combining OB, PA, RSI and BB
   Signal GetSignal()
   {
      Signal s; s.isValid = false;
      if(!init_handles()) return s;

      // Buffers
      double rsi[];   ArraySetAsSeries(rsi,   true);
      double bb_up[], bb_lo[]; ArraySetAsSeries(bb_up, true); ArraySetAsSeries(bb_lo, true);

      // Copy indicator values
      CopyBuffer(hRSI, 0, 0, 1, rsi);
      CopyBuffer(hBB,  1, 0, 1, bb_up);
      CopyBuffer(hBB,  2, 0, 1, bb_lo);

      double price = SymbolInfoDouble(EA_SYMBOL, SYMBOL_BID);
      bool oversold   = (rsi[0] < 33 && price <= bb_lo[0]);
      bool overbought = (rsi[0] > 66 && price >= bb_up[0]);
      if(!oversold && !overbought) return s;
      bool buy = oversold;

      // Order block price
      double ob_mid = DetectOrderBlock(PERIOD_H1);
      if(ob_mid == 0) return s;
      if( (buy  && price > ob_mid) || (!buy && price < ob_mid) ) return s;

      // Trigger candle check
      if(!is_trigger(buy)) return s;
      
       // Require at least one FVG on H1 or H4 timeframe
      //if(!DetectFVG(PERIOD_H1)) return s;
      
      // Require current price to be within a liquidity zone
      //if(!InLiquidityZone()) return s;
      
            // Additional filter: price proximity to recent extremes
      const int rangeBars = 150; // lookback range in bars
      double highestHigh = iHigh(EA_SYMBOL, PERIOD_H1, 1);
      double lowestLow    = iLow(EA_SYMBOL, PERIOD_H1, 1);
      for(int j = 2; j <= rangeBars; ++j)
      {
         highestHigh = MathMax(highestHigh, iHigh(EA_SYMBOL, PERIOD_H1, j));
         lowestLow    = MathMin(lowestLow,  iLow(EA_SYMBOL,  PERIOD_H1, j));
      }
      double pctThreshold = 0.005; // 0.5%
      if(buy)
      {
         // entry must be within 0.5% above lowest low
         if(price > lowestLow * (1.0 + pctThreshold))
            return s;
      }
      else
      {
         // entry must be within 0.5% below highest high
         if(price < highestHigh * (1.0 - pctThreshold))
            return s;
      }
      
      // Build signal (SL/TP later by RiskManager)
      s.isValid = true;
      s.isBuy   = buy;
      s.sl      = 0;
      s.tp      = 0;
      return s;
   }
}

#endif // TECHNICALENGINE_MQH
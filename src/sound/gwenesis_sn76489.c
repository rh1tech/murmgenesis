/*
    SN76489 emulation
    Based on Maxim's original implementation (2001-2002)
    with improvements from Genesis Plus GX by Eke-Eke

    Genesis Plus GX improvements:
    - Proper discrete vs integrated chip type support
    - Accurate -2dB volume table from hardware measurements
    - Correct noise shift register width and feedback

    07/08/04  Charles MacDonald
    Modified for use with SMS Plus:
    - Added support for multiple PSG chips.
    - Added reset/config/update routines.
    - Added context management routines.
    - Removed SN76489_GetValues().
    - Removed some unused variables.

    07/08/04  bzhxx few simplication for gwenesis to fit on MCU
*/


#include <string.h>
#include <stdlib.h>
#include <stdarg.h>
#include <signal.h>
#include <stdio.h>
#include <math.h>
#include <limits.h>
#include "gwenesis_bus.h"
#include "gwenesis_sn76489.h"
#include "gwenesis_savestate.h"

#define PSG_CUTOFF          0x6     /* Value below which PSG does not output */

/* Noise feedback lookup table (from Genesis Plus GX)
   Used for XOR feedback calculation on white noise */
static const uint8 noiseFeedback[10] = {0,1,1,0,1,0,0,1,1,0};

/* Accurate volume table with -2dB steps (from Genesis Plus GX)
   Measured from actual hardware */
#define PSG_MAX_VOLUME 2800
static const int PSGVolumeValues[16] = {
    PSG_MAX_VOLUME,                               /*  MAX  */
    (int)(PSG_MAX_VOLUME * 0.794328234),          /* -2dB  */
    (int)(PSG_MAX_VOLUME * 0.630957344),          /* -4dB  */
    (int)(PSG_MAX_VOLUME * 0.501187233),          /* -6dB  */
    (int)(PSG_MAX_VOLUME * 0.398107170),          /* -8dB  */
    (int)(PSG_MAX_VOLUME * 0.316227766),          /* -10dB */
    (int)(PSG_MAX_VOLUME * 0.251188643),          /* -12dB */
    (int)(PSG_MAX_VOLUME * 0.199526231),          /* -14dB */
    (int)(PSG_MAX_VOLUME * 0.158489319),          /* -16dB */
    (int)(PSG_MAX_VOLUME * 0.125892541),          /* -18dB */
    (int)(PSG_MAX_VOLUME * 0.1),                  /* -20dB */
    (int)(PSG_MAX_VOLUME * 0.079432823),          /* -22dB */
    (int)(PSG_MAX_VOLUME * 0.063095734),          /* -24dB */
    (int)(PSG_MAX_VOLUME * 0.050118723),          /* -26dB */
    (int)(PSG_MAX_VOLUME * 0.039810717),          /* -28dB */
    0                                             /*  OFF  */
};

static SN76489_Context gwenesis_SN76489;

void gwenesis_SN76489_Init(int PSGClockValue, int SamplingRate, int freq_divisor, int type)
{
    gwenesis_SN76489.dClock=(float)PSGClockValue/16/SamplingRate;
    gwenesis_SN76489.divisor = freq_divisor;
    
    /* Setup chip type parameters (from Genesis Plus GX) */
    if (type == PSG_DISCRETE) {
        /* Original SN76489A discrete chip */
        gwenesis_SN76489.noiseShiftWidth = 14;
        gwenesis_SN76489.noiseBitMask = 0x6;    /* Bits 1 and 2 */
        gwenesis_SN76489.zeroFreqValue = 0x400; /* Behaves as 0x400 on discrete */
        gwenesis_SN76489.WhiteNoiseFeedback = 0x0006;
    } else {
        /* Integrated ASIC clone (later revisions) */
        gwenesis_SN76489.noiseShiftWidth = 15;
        gwenesis_SN76489.noiseBitMask = 0x9;    /* Bits 0 and 3 */
        gwenesis_SN76489.zeroFreqValue = 0x1;   /* Behaves as 0x1 on integrated */
        gwenesis_SN76489.WhiteNoiseFeedback = 0x0009;
    }

    gwenesis_SN76489_Reset();
}

void gwenesis_SN76489_Reset()
{
    int i;

    for(i = 0; i <= 2; i++)
    {
        /* Initialise tone PSG state */
        gwenesis_SN76489.Registers[2*i] = 1;         /* tone freq=1 */
        gwenesis_SN76489.Registers[2*i+1] = 0xf;     /* vol=off */

        /* Set counters to 0 */
        gwenesis_SN76489.ToneFreqVals[i] = 0;

        /* Set flip-flops to -1 (low) as per Genesis Plus GX */
        gwenesis_SN76489.ToneFreqPos[i] = -1;

        /* Set intermediate positions to do-not-use value */
        gwenesis_SN76489.IntermediatePos[i] = LONG_MIN;
    }
    
    /* Initialize noise channel (channel 3) */
    gwenesis_SN76489.Registers[6] = 0x00;        /* Noise control */
    gwenesis_SN76489.Registers[7] = 0xf;         /* Noise vol=off */
    gwenesis_SN76489.NoiseFreq = 0x10;
    gwenesis_SN76489.ToneFreqVals[3] = 0;
    gwenesis_SN76489.ToneFreqPos[3] = -1;
    gwenesis_SN76489.IntermediatePos[3] = LONG_MIN;

    /* Tone #2 attenuation register is latched on power-on (verified in Genesis Plus GX) */
    gwenesis_SN76489.LatchedRegister = 3;

    /* Initialise noise generator with proper shift width (from Genesis Plus GX) */
    gwenesis_SN76489.NoiseShiftRegister = 1 << gwenesis_SN76489.noiseShiftWidth;

    /* Zero clock */
    gwenesis_SN76489.Clock=0;
    sn76489_index=0;
    sn76489_clock=0;

}

void gwenesis_SN76489_SetContext(uint8 *data)
{
    memcpy(&gwenesis_SN76489, data, sizeof(SN76489_Context));
}

void gwenesis_SN76489_GetContext(uint8 *data)
{
    memcpy(data, &gwenesis_SN76489, sizeof(SN76489_Context));
}

uint8 *gwenesis_SN76489_GetContextPtr()
{
    return (uint8 *)&gwenesis_SN76489;
}

int gwenesis_SN76489_GetContextSize(void)
{
    return sizeof(SN76489_Context);
}
static inline void gwenesis_SN76489_Update(INT16 *buffer, int length)
{
    int i, j;

    for(j = 0; j < length; j++)
    {
        for (i=0;i<=2;++i)
            if (gwenesis_SN76489.IntermediatePos[i]!=LONG_MIN)
                gwenesis_SN76489.Channels[i]=PSGVolumeValues[gwenesis_SN76489.Registers[2*i+1]]*gwenesis_SN76489.IntermediatePos[i]/65536;
            else
                gwenesis_SN76489.Channels[i]=PSGVolumeValues[gwenesis_SN76489.Registers[2*i+1]]*gwenesis_SN76489.ToneFreqPos[i];

        gwenesis_SN76489.Channels[3]=(short)(PSGVolumeValues[gwenesis_SN76489.Registers[7]]*(gwenesis_SN76489.NoiseShiftRegister & 0x1));

        gwenesis_SN76489.Channels[3]<<=1; /* Double noise volume to make some people happy */

        buffer[j] = (gwenesis_SN76489.Channels[0]);
        buffer[j] += (gwenesis_SN76489.Channels[1]);
        buffer[j] += (gwenesis_SN76489.Channels[2]);
        buffer[j] += (gwenesis_SN76489.Channels[3]);

        gwenesis_SN76489.Clock+=gwenesis_SN76489.dClock;
        gwenesis_SN76489.NumClocksForSample=(int)gwenesis_SN76489.Clock;  /* truncates */
        gwenesis_SN76489.Clock-=gwenesis_SN76489.NumClocksForSample;  /* remove integer part */

        /* Decrement tone channel counters */
        for (i=0;i<=2;++i)
            gwenesis_SN76489.ToneFreqVals[i]-=gwenesis_SN76489.NumClocksForSample;

        /* Noise channel: match to tone2 or decrement its counter */
        if (gwenesis_SN76489.NoiseFreq==0x80) gwenesis_SN76489.ToneFreqVals[3]=gwenesis_SN76489.ToneFreqVals[2];
        else gwenesis_SN76489.ToneFreqVals[3]-=gwenesis_SN76489.NumClocksForSample;

        /* Tone channels: */
        for (i=0;i<=2;++i) {
            if (gwenesis_SN76489.ToneFreqVals[i]<=0) {   /* If it gets below 0... */
                if (gwenesis_SN76489.Registers[i*2]>PSG_CUTOFF) {
                    /* Calculate how much of the sample is + and how much is - */
                    /* Go to floating point and include the clock fraction for extreme accuracy :D */
                    /* Store as long int, maybe it's faster? I'm not very good at this */
                    gwenesis_SN76489.IntermediatePos[i]=(long)((gwenesis_SN76489.NumClocksForSample-gwenesis_SN76489.Clock+2*gwenesis_SN76489.ToneFreqVals[i])*gwenesis_SN76489.ToneFreqPos[i]/(gwenesis_SN76489.NumClocksForSample+gwenesis_SN76489.Clock)*65536);
                    gwenesis_SN76489.ToneFreqPos[i]=-gwenesis_SN76489.ToneFreqPos[i]; /* Flip the flip-flop */
                } else {
                    gwenesis_SN76489.ToneFreqPos[i]=1;   /* stuck value */
                    gwenesis_SN76489.IntermediatePos[i]=LONG_MIN;
                }
                gwenesis_SN76489.ToneFreqVals[i]+=gwenesis_SN76489.Registers[i*2]*(gwenesis_SN76489.NumClocksForSample/gwenesis_SN76489.Registers[i*2]+1);
            } else gwenesis_SN76489.IntermediatePos[i]=LONG_MIN;
        }

        /* Noise channel (with Genesis Plus GX improvements) */
        if (gwenesis_SN76489.ToneFreqVals[3]<=0) {   /* If it gets below 0... */
            gwenesis_SN76489.ToneFreqPos[3]=-gwenesis_SN76489.ToneFreqPos[3]; /* Flip the flip-flop */
            if (gwenesis_SN76489.NoiseFreq!=0x80)            /* If not matching tone2, decrement counter */
                gwenesis_SN76489.ToneFreqVals[3]+=gwenesis_SN76489.NoiseFreq*(gwenesis_SN76489.NumClocksForSample/gwenesis_SN76489.NoiseFreq+1);
            
            /* Noise register is shifted on positive edge only (from Genesis Plus GX) */
            if (gwenesis_SN76489.ToneFreqPos[3]==1) {
                int shiftOutput = gwenesis_SN76489.NoiseShiftRegister & 0x01;
                
                if (gwenesis_SN76489.Registers[6]&0x4) { /* White noise */
                    /* Use XOR feedback lookup table (from Genesis Plus GX) */
                    int feedbackBits = gwenesis_SN76489.NoiseShiftRegister & gwenesis_SN76489.noiseBitMask;
                    int feedback = noiseFeedback[feedbackBits];
                    gwenesis_SN76489.NoiseShiftRegister = (gwenesis_SN76489.NoiseShiftRegister >> 1) | 
                        (feedback << gwenesis_SN76489.noiseShiftWidth);
                } else {  /* Periodic noise */
                    /* Shift and feedback current output */
                    gwenesis_SN76489.NoiseShiftRegister = (gwenesis_SN76489.NoiseShiftRegister >> 1) | 
                        (shiftOutput << gwenesis_SN76489.noiseShiftWidth);
                }
            }
        }
    }
}
/* SN76589 execution */
extern int scan_line;
void gwenesis_SN76489_run(int target) {
 
if ( sn76489_clock >= target) return;

  int sn76489_prev_index = sn76489_index;
  sn76489_index += (target-sn76489_clock) / gwenesis_SN76489.divisor;
  
  /* Bounds check - prevent buffer overflow */
  /* Buffer size is 4096 samples */
  if (sn76489_index > 4095) {
    sn76489_index = 4095;
  }
  
  if (sn76489_index > sn76489_prev_index) {
    gwenesis_SN76489_Update(gwenesis_sn76489_buffer + sn76489_prev_index, sn76489_index-sn76489_prev_index);
    sn76489_clock = sn76489_index*gwenesis_SN76489.divisor;
  } else {
    sn76489_index = sn76489_prev_index;
  }
}
void gwenesis_SN76489_Write(int data, int target)
{
  if (GWENESIS_AUDIO_ACCURATE == 1)
    gwenesis_SN76489_run(target);

  if (data & 0x80) {
    /* Latch/data byte  %1 cc t dddd */
    gwenesis_SN76489.LatchedRegister = ((data >> 4) & 0x07);
    gwenesis_SN76489.Registers[gwenesis_SN76489.LatchedRegister] =
        (gwenesis_SN76489.Registers[gwenesis_SN76489.LatchedRegister] &
         0x3f0)         /* zero low 4 bits */
        | (data & 0xf); /* and replace with data */
	} else {
        /* Data byte        %0 - dddddd */
        if (!(gwenesis_SN76489.LatchedRegister%2)&&(gwenesis_SN76489.LatchedRegister<5))
            /* Tone register */
            gwenesis_SN76489.Registers[gwenesis_SN76489.LatchedRegister]=
                (gwenesis_SN76489.Registers[gwenesis_SN76489.LatchedRegister] & 0x00f)    /* zero high 6 bits */
                | ((data&0x3f)<<4);                     /* and replace with data */
		else
            /* Other register */
            gwenesis_SN76489.Registers[gwenesis_SN76489.LatchedRegister]=data&0x0f;       /* Replace with data */
    }
    switch (gwenesis_SN76489.LatchedRegister) {
	case 0:
	case 2:
    case 4: /* Tone channels */
        /* Zero frequency handling based on chip type (from Genesis Plus GX) */
        if (gwenesis_SN76489.Registers[gwenesis_SN76489.LatchedRegister]==0) 
            gwenesis_SN76489.Registers[gwenesis_SN76489.LatchedRegister]=gwenesis_SN76489.zeroFreqValue;
		break;
    case 6: /* Noise */
        /* Reset shift register with proper width (from Genesis Plus GX) */
        gwenesis_SN76489.NoiseShiftRegister = 1 << gwenesis_SN76489.noiseShiftWidth;
        gwenesis_SN76489.NoiseFreq=0x10<<(gwenesis_SN76489.Registers[6]&0x3);     /* set noise signal generator frequency */
		break;
    }
}

void gwenesis_sn76489_save_state() {
  SaveState* state;
  state = saveGwenesisStateOpenForWrite("sn76489");
  saveGwenesisStateSetBuffer(state, "gwenesis_SN76489", &gwenesis_SN76489, sizeof(gwenesis_SN76489));

}

void gwenesis_sn76489_load_state() {
  SaveState* state = saveGwenesisStateOpenForRead("sn76489");
  saveGwenesisStateGetBuffer(state, "gwenesis_SN76489", &gwenesis_SN76489, sizeof(gwenesis_SN76489));

}

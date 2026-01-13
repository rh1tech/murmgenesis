
#ifndef _GWENESIS_SN76489_H_
#define _GWENESIS_SN76489_H_

/*
    SN76489 emulation based on Maxim's implementation
    with improvements from Genesis Plus GX

    Supports discrete and integrated chip variants
*/

/* PSG chip type (from Genesis Plus GX) */
enum {
    PSG_DISCRETE = 0,  /* SN76489A discrete chip (original) */
    PSG_INTEGRATED     /* ASIC integrated clone (later revisions) */
};

#undef uint8
#undef uint16
#undef uint32
#undef uint64

typedef unsigned char uint8;
typedef unsigned short int uint16;
typedef unsigned int uint32;

typedef signed char int8;
typedef signed short int int16;
typedef signed int int32;

typedef unsigned char UINT8;
typedef unsigned short int UINT16;
typedef unsigned int UINT32;

typedef signed char INT8;
typedef signed short int INT16;
typedef signed int INT32;
typedef long signed int INT64;

typedef struct
{
    /* Variables */
    float Clock;
    float dClock;
    int NumClocksForSample;
    int WhiteNoiseFeedback;
    int divisor;

    /* Chip type parameters (from Genesis Plus GX) */
    int noiseShiftWidth;    /* 14 for discrete, 15 for integrated */
    int noiseBitMask;       /* 0x6 for discrete, 0x9 for integrated */
    int zeroFreqValue;      /* 0x400 for discrete, 0x1 for integrated */

    /* PSG registers: */
    UINT16 Registers[8];        /* Tone, vol x4 */
    int LatchedRegister;
    UINT16 NoiseShiftRegister;
    INT16 NoiseFreq;            /* Noise channel signal generator frequency */

    /* Output calculation variables */
    INT16 ToneFreqVals[4];      /* Frequency register values (counters) */
    INT8 ToneFreqPos[4];        /* Frequency channel flip-flops */
    INT16 Channels[4];          /* Value of each channel, before stereo is applied */
    INT64 IntermediatePos[4];   /* intermediate values used at boundaries between + and - */

} SN76489_Context;

extern int16 *gwenesis_sn76489_buffer;
extern volatile int sn76489_index;
extern volatile int sn76489_clock;

/* Function prototypes */
void gwenesis_SN76489_Init(int PSGClockValue, int SamplingRate, int freq_divisor, int type);
void gwenesis_SN76489_Reset();
void gwenesis_SN76489_start();
void gwenesis_SN76489_SetContext(uint8 *data);
void gwenesis_SN76489_GetContext(uint8 *data);
uint8 *gwenesis_SN76489_GetContextPtr();
int gwenesis_SN76489_GetContextSize(void);
void gwenesis_SN76489_Write(int data, int target);
void gwenesis_SN76489_run(int target);

void gwenesis_sn76489_save_state();
void gwenesis_sn76489_load_state();

#endif /* _GWENESIS_SN76489_H_ */

; Sinus Generator

.DEVICE atmega328p

.dseg
abFSIdx: .Byte 12                       ; wave sample indices, each element points to a sample inside a different wave

.cseg

.org    0x0000
        rjmp    setup                   ; register 'setup' as Programm Start Routine
        
.org    OVF0addr
        rjmp    isr_timer0              ; register 'isr_timer0' as Timer0 Overflow Routine

; these should have be known in the environment, gavrasm doesn't know them
.def YL         = r28
.def YH         = r29
.def ZL         = r30
.def ZH         = r31

; names for the registers to help humans to understand
.def nOne       = r1
.def nNULL      = r16
.def ZLsave     = r17
.def ZHsave     = r18
.def nSmpIx     = r19
.def nSmpVe     = r20
.def nBits      = r21
.def nBitsL     = r21   ; same as nBits for SW-DAC
.def nBitsH     = r22
.def mOutL      = r22   ; same as nBitsH, which is no longer needed if mOutL will be filled
.def mOutH      = r23
.def rTemp      = r24
.def cNextWave  = r25
.def mInputVal  = r26   ; ! special register X
.def mInputBit  = r27   ; ! special register X

;  C	*   523.25 Hz
;CIS	*   554.37 Hz
;  D	*   587.33 Hz
;DIS	*   622.25 Hz
;  E	*   659.26 Hz
;  F	*   698.46 Hz
;FIS	*   739.99 Hz
;  G	*   783.99 Hz
;GIS	*   830.61 Hz
;  A	*   880.00 Hz
;  B	*   932.33 Hz
;  H	*   987.77 Hz

; 2 byte timing, Interrupt Generator has to be adjusted to 64*'C' = 33488 Hz

;.equ    TPBH    = 0xfc                              ; High Byte des Timer Presets
;.equ    TPBL    = 0x48                              ; Low  Byte des Timer Presets

.equ    TPBH    = 0xfe                              ; High Byte des Timer Presets
.equ    TPBL    = 0x24                              ; Low  Byte des Timer Presets

; ==================================================
; SETUP INTERRUPT MECHANICS
; ones per program start
; ==================================================

    setup:

; setup interrupt generation

            cli                                     ; do not generate interrupts while setup phase

            ldi     rTemp,      LOW (RAMEND)        ; initializing stack pointer
            out     SPL,        rTemp               ; -- " --
            ldi     rTemp,      HIGH(RAMEND)        ; -- " --
            out     SPH,        rTemp               ; -- " --

            ldi     rTemp,      0x00                ; set time1 to "no waveform generation & no compare match interrupt"
            sts     TCCR1A,     rTemp               ; -- " --
            ldi     rTemp,      0x01                ; set timer1 prescaler to 1
            sts     TCCR1B,     rTemp               ; -- " --

            ldi     rTemp,      0x02                ; set time1 to overflow interrupt timer
            sts     TIMSK1,     rTemp               ; -- " --

            ldi     rTemp,      TPBH                ; adjust timer for next interrupt
            sts     TCNT1H,     rTemp               ; -- " --
            ldi     rTemp,      TPBL                ; -- " --
            sts     TCNT1L,     rTemp               ; -- " --

; PORT definition

            ldi     r16,        0x00                ; r16 to input mode for all pins
            ldi     r17,        0xFF                ; all pins to pullup
            ldi     r18,        0xFF                ; all pins to output

; define PORTB as input

            out     DDRC,       r16                 ; set input pins
            out     PORTC,      r17                 ; set pullup mode

; define PORTD as output

            out     DDRD,       r18                 ; set output pins
            ldi     r18,        0x0F                ; onle the lower 4 bits to output
            out     DDRB,       r18

; from here on we will use register alias names as far as possible

; initialize a register with NULL for later use

            eor     nNULL,      nNULL               ; we need a NULL in a register :-(
            eor     nOne,       nOne                ; we need a 1 too :-((
            inc     nOne                            ; no ldi with r1 :-(((

; initialize all Frequency-Sample-Indices with "0"

            ldi     YL,         low (abFSIdx*2)       ; list of indices of next sample in wave
            ldi     YH,         high(abFSIdx*2)       ;   -- " --

            ldi     r17,        0x01                ; the next address lies "1" further on
            ldi     r18,        0x0C                ; 12 Tunes
    FSIdx:
            st      Y,          nNULL               ; 0 => abFSIdx[n]
            add     YL,         r17                 ; next address (n++)
            adc     YH,         nNULL               ;   -- " --
            dec     r18                             ; one done
            brne    FSIdx                           ; more to do?

            sei                                     ; setup is finished, allow generation of interrupts

    wait:
            rjmp wait                               ; wait for ever, interrupt is called as configured

; ==================================================
; START OF THE INTERRUPT SERVICE ROUTINE
; ==================================================

    isr_timer0:

; (re)adjust timer for next interrupt

            ldi     rTemp,      TPBH
            sts     TCNT1H,     rTemp
            ldi     rTemp,      TPBL
            sts     TCNT1L,     rTemp

; --------------------------------------------------
; initial address calculation
; --------------------------------------------------

; list of sample indices into the wave to Y

            ldi     YL,         low (abFSIdx*2)       ; load Y to point to the start of frequence sample index array "C"
            ldi     YH,         high(abFSIdx*2)       ;   -- " --

; start pointer of the wave to Z and to copy registers

            ldi     ZL,         low (abWaveSet*2)     ; load Z to point to start of 2D wave matrix
            ldi     ZH,         high(abWaveSet*2)     ;   -- " --
            mov     ZLsave,     ZL                  ; sometimes we need the startpoint again later on
            mov     ZHsave,     ZH                  ;   -- " --

; reset output value (sample sum)

            eor     nBitsL,     nBitsL
            eor     nBitsH,     nBitsH

; start on input pin 0

            ldi     mInputBit,  0x01                ; starting the big loop
            ror     mInputBit                       ; set carry flag

; --------------------------------------------------
; main loop: read in the input signal status
; --------------------------------------------------

    read:
            rol     mInputBit                       ; the first bit loures in the carry flag
            sbrc    mInputBit,  0x06                ; the last bit we are allowed to start a run
            rjmp    dac

            in      mInputVal,  PINC                ; check whats ON
            and     mInputVal,  mInputBit
            breq    run                             ; a bit is 0, so we have to make a run for it

            add     YL,         nOne                ; the next element of the frequence vector abFSIdx
            adc     YH,         nNULL

            ldi     rTemp,      64                  ; the next wave
            add     ZLsave,     rTemp
            adc     ZHsave,     nNULL

            rjmp    read                            ; check the next pin/key

; load start address of the next wave

    run:
            mov     ZL,         ZLsave              ; sometimes we need the start again later on
            mov     ZH,         ZHsave              ;   -- " --

; add index of current 'sample in wave' pointer

            ld      nSmpIx,     Y                   ; abFSIdx[n] => register nSmpIx
            add     ZL,         nSmpIx              ; add nSmpIx to wave pointer &abWaveSet[abFSIdx[n]]
            adc     ZH,         nNULL

; get and check the next sample

    strt1:
            lpm                                     ; load [Z] to r0
            tst     r0                              ; set the flag regarding to the content
            brne    next1                           ; if not 0, we have the sample

            eor     r0,         r0                  ; the assumed sample value is 2 - the average end value
            inc     r0
            inc     r0

; end of wave, restart the wave

            mov     ZL,         ZLsave              ; reset Z to start of current wave to enable jump to the next wave
            mov     ZH,         ZHsave              ;   -- " --
            mov     nSmpIx,     nNULL               ; the sample pointer becomes 0 too to restart the current wave
            rjmp    next2                           ; we must no increment our nSmpIx, because it is already correct

; make address of next 'sample in wave' pointer

    next1:
            inc     nSmpIx                          ; next time the next sample
    next2:
            st      Y,          nSmpIx              ; write back to abFSIdx

; adding the sample to the sum of samples

            add     nBitsL,     r0                  ; accumulate all samples of all runs 
            adc     nBitsH,     nNULL

; test if all keys were checked

            sbrs    mInputBit,  0x05                ; reached the last bit we will read?
            rjmp    read                            ; no, so we go to the next step

; output sample value

; --------------------------------------------------
; D-to-A-Converter
; --------------------------------------------------

; divide by 32 to scale down into a 0 to 6 range (38 would be better)

; we expect maximum value of lower than 255*12=3060 if we are using
; an external D/A converter

; for development we use direct D to A conversion
; With direct D to A convertion we are able to output
; 12 bits. So we have to scale the maximum expected
; amount of simultanious tones to a maximum amplitude
; of 12 bits!
; tones  reverse division     divisor  bits    offset
;  1      255 / 12 =  21.25     32      7.97    16
;  2      510 / 12 =  42.50     64      7.97    32
;  3      765 / 12 =  63.75     64     11.95    32
;  4     1020 / 12 =  85.00    128      7.97    64
;  5     1275 / 12 = 106.25    128      9.96    64
;  6     1530 / 12 = 127.50    128     11.95    64

    dac:                                            ; Digital to Analog converter

    dby128:                                         ; 4 to 6 tones
            lsr     nBitsL                          ; /128
            sbrc    nBitsH,     0
            ori     nBitsL,     0x80
            lsr     nBitsH
    dby064:                                         ; 2 to 3 tones
            lsr     nBitsL                          ; /64
            sbrc    nBitsH,     0
            ori     nBitsL,     0x80
            lsr     nBitsH
    dby032:                                         ; 1 tone
            lsr     nBitsL                          ; /32
            sbrc    nBitsH,     0
            ori     nBitsL,     0x80
            lsr     nBitsH
    dby016:
            lsr     nBitsL                          ; /16
            sbrc    nBitsH,     0
            ori     nBitsL,     0x80
            lsr     nBitsH

            lsr     nBits                           ; /8
            lsr     nBits                           ; /4
            lsr     nBits                           ; /2

; cummulate bits

            eor     mOutL,       mOutL              ; initialize output byte
            eor     mOutH,       mOutH              ; initialize output byte

            inc     nBits                           ; prepair nBits-loop
    for:    
            dec     nBits                           ; loop for bits to set
            breq    end                             ; break if no bits to set anymore

            lsl     mOutL                            ; shift existing bits
            rol     mOutH
            ori     mOutL,      0x01                ; inject a bit
            rjmp    for                             ; loop to-for

; --------------------------------------------------
; output resulting sample sum (here DA Convertet)
; --------------------------------------------------

    end:
            out     PORTD,      mOutL               ; output result
            out     PORTB,      mOutH
            reti                                    ; close the book


abWaveSet:
;	little endian
;    === ===============================================================================================================================================================================================================================
C:	.dw 0x0201,0x0603,0x100B,0x1E16,0x2F26,0x4439,0x5B4F,0x7467,0x8C80,0xA599,0xBCB1,0xD1C7,0xE2DA,0xF0EA,0xFAF5,0xFEFD,0xFEFF,0xFAFD,0xF0F5,0xE2EA,0xD1DA,0xBCC7,0xA5B1,0x8C99,0x7480,0x5B67,0x444F,0x2F39,0x1E26,0x1016,0x060B,0x0003
CIS:	.dw 0x0201,0x0704,0x120C,0x2119,0x352A,0x4B40,0x6458,0x7F71,0x998C,0xB2A6,0xC9BE,0xDDD4,0xEDE5,0xF8F3,0xFEFC,0xFFFF,0xFAFD,0xF0F5,0xE1E9,0xCDD7,0xB7C3,0x9EAB,0x8491,0x6A77,0x505D,0x3944,0x252F,0x151C,0x090E,0x0005,0x0000,0x0000
D:	.dw 0x0201,0x0804,0x140D,0x251C,0x3B2F,0x5347,0x6F61,0x8A7C,0xA698,0xBFB3,0xD6CB,0xE8E0,0xF6F0,0xFDFA,0xFFFF,0xFAFD,0xF0F6,0xE0E8,0xCBD6,0xB3C0,0x99A6,0x7D8B,0x616F,0x4754,0x2F3B,0x1C25,0x0D14,0x0408,0x0000,0x0000,0x0000,0x0000
DIS:	.dw 0x0201,0x0904,0x160F,0x291F,0x4134,0x5C4E,0x796B,0x9788,0xB3A5,0xCDC0,0xE2D8,0xF2EB,0xFCF8,0xFFFE,0xFBFE,0xF1F7,0xE0E9,0xCAD6,0xB1BE,0x94A3,0x7785,0x5A68,0x3F4C,0x2732,0x151D,0x080D,0x0004,0x0000,0x0000,0x0000,0x0000,0x0000
E:	.dw 0x0201,0x0A05,0x1910,0x2E22,0x483A,0x6656,0x8575,0xA494,0xC0B2,0xD9CD,0xEDE4,0xF9F4,0xFFFD,0xFDFF,0xF3F8,0xE2EB,0xCBD7,0xAFBE,0x91A1,0x7282,0x5362,0x3845,0x202B,0x0F17,0x0409,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000
F:	.dw 0x0201,0x0B05,0x1B12,0x3326,0x5041,0x705F,0x9180,0xB1A1,0xCEC0,0xE5DA,0xF5EE,0xFEFB,0xFEFF,0xF5FB,0xE4EE,0xCDD9,0xB0BF,0x90A0,0x6F7F,0x4F5E,0x3240,0x1B26,0x0A12,0x0005,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000
FIS:	.dw 0x0201,0x0C06,0x1E14,0x382B,0x5848,0x7A69,0x9D8C,0xBEAE,0xDACD,0xEFE6,0xFCF7,0xFFFF,0xF8FD,0xE8F1,0xD0DD,0xB2C2,0x91A2,0x6D7F,0x4C5C,0x2E3C,0x1721,0x070E,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000
G:	.dw 0x0201,0x0D06,0x2216,0x3F2F,0x614F,0x8673,0xAB99,0xCBBC,0xE6DA,0xF7F0,0xFFFC,0xFBFE,0xEDF6,0xD6E3,0xB7C7,0x93A5,0x6E81,0x4A5C,0x2B3A,0x131E,0x050B,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000
GIS:	.dw 0x0301,0x0F07,0x2619,0x4535,0x6B58,0x927E,0xB8A5,0xD8C9,0xF0E5,0xFDF8,0xFEFF,0xF3FA,0xDDE9,0xBDCE,0x98AB,0x7185,0x4B5E,0x2A3A,0x121D,0x0009,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000
A:	.dw 0x0301,0x1008,0x2A1C,0x4D3A,0x7561,0x9F8A,0xC5B3,0xE4D6,0xF8EF,0xFFFD,0xF8FD,0xE5F0,0xC6D7,0xA0B4,0x768B,0x4E62,0x2B3B,0x111C,0x0008,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000
B:	.dw 0x0301,0x1209,0x2F1F,0x5541,0x806A,0xAC97,0xD2C0,0xEEE2,0xFDF8,0xFDFF,0xEDF7,0xD1E1,0xAABE,0x7F95,0x5369,0x2D3F,0x111E,0x0008,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000
H:	.dw 0x0301,0x140A,0x3422,0x5E48,0x8C75,0xB9A3,0xDECD,0xF7EC,0xFFFD,0xF6FD,0xDDEB,0xB7CB,0x8AA1,0x5C73,0x3246,0x1321,0x0009,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000
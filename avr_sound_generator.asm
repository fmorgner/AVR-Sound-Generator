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
.def mOut       = r23
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

.equ    TPBH    = 0xfc                              ; High Byte des Timer Presets
.equ    TPBL    = 0x48                              ; Low  Byte des Timer Presets

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
            ldi     r17,        0xFF                ; all pins to input
            ldi     r18,        0xFF                ; all pins to output

; define PORTB as input

            out     DDRC,       r16                 ; set input pins
            out     PORTC,      r17                 ; set pullup mode

; define PORTD as output

            out     DDRD,       r18                 ; set output pins

; from here on we will use register alias names as far as possible

; initialize a register with NULL for later use

            eor     nNULL,      nNULL               ; we need a NULL in a register :-(
            eor     nOne,       nOne                ; we need a 1 too :-((
            inc     nOne                            ; no ldi with r1 :-(((

; initialize all Frequency-Sample-Indices with "0"

            ldi     YL,         low (abFSIdx)       ; list of indices of next sample in wave
            ldi     YH,         high(abFSIdx)       ;   -- " --

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

            ldi     YL,         low (abFSIdx)       ; load Y to point to the start of frequence sample index array "C"
            ldi     YH,         high(abFSIdx)       ;   -- " --

; start pointer of the wave to Z and to copy registers

            ldi     ZL,         low (abWaveSet)     ; load Z to point to start of 2D wave matrix
            ldi     ZH,         high(abWaveSet)     ;   -- " --
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

    dac:                                            ; Digital to Analog converter
    
            lsr     nBitsL                          ; divide two bytes by two
            sbrc    nBitsH,     0                   ;   -- " --
            ori     nBitsL,     0x80                ;   -- " --
            lsr     nBitsH                          ;   -- " --

            lsr     nBitsL
            sbrc    nBitsH,     0
            ori     nBitsL,     0x80
            lsr     nBitsH

            lsr     nBitsL
            sbrc    nBitsH,     0
            ori     nBitsL,     0x80
            lsr     nBitsH

            lsr     nBitsL
            sbrc    nBitsH,     0
            ori     nBitsL,     0x80
            lsr     nBitsH

            lsr     nBitsL
            sbrc    nBitsH,     0
            ori     nBitsL,     0x80
            lsr     nBitsH

            lsr     nBits                           ; divide one byte by two

; cummulate bits

            eor     mOut,       mOut                ; initialize output byte

            inc     nBits                           ; prepair nBits-loop
    for:    
            dec     nBits                           ; loop for bits to set
            breq    end                             ; break if no bits to set anymore

            lsl     mOut                            ; shift existing bits
            ori     mOut,       0x04                ; inject bit
            rjmp    for                             ; loop to-for

; --------------------------------------------------
; output resulting sample sum (here DA Convertet)
; --------------------------------------------------

    end:
            out     PORTD,      mOut                ; output result

            reti                                    ; close the book


abWaveSet:
;    === ===============================================================================================================================================================================================================================
C:   .dw 0x0102,0x0306,0x0B10,0x161E,0x262F,0x3944,0x4F5B,0x6774,0x808C,0x99A5,0xB1BC,0xC7D1,0xDAE2,0xEAF0,0xF5FA,0xFDFE,0xFFFE,0xFDFA,0xF5F0,0xEAE2,0xDAD1,0xC7BC,0xB1A5,0x998C,0x8074,0x675B,0x4F44,0x392F,0x261E,0x1610,0x0B06,0x0302
CIS: .dw 0x0102,0x0407,0x0C12,0x1921,0x2A35,0x404B,0x5864,0x717F,0x8C99,0xA6B2,0xBEC9,0xD4DD,0xE5ED,0xF3F8,0xFCFE,0xFFFF,0xFDFA,0xF5F0,0xE9E1,0xD7CD,0xC3B7,0xAB9E,0x9184,0x776A,0x5D50,0x4439,0x2F25,0x1C15,0x0E09,0x0502,0x0000,0x0000
D:   .dw 0x0102,0x0408,0x0D14,0x1C25,0x2F3B,0x4753,0x616F,0x7C8A,0x98A6,0xB3BF,0xCBD6,0xE0E8,0xF0F6,0xFAFD,0xFFFF,0xFDFA,0xF6F0,0xE8E0,0xD6CB,0xC0B3,0xA699,0x8B7D,0x6F61,0x5447,0x3B2F,0x251C,0x140D,0x0804,0x0200,0x0000,0x0000,0x0000
DIS: .dw 0x0102,0x0409,0x0F16,0x1F29,0x3441,0x4E5C,0x6B79,0x8897,0xA5B3,0xC0CD,0xD8E2,0xEBF2,0xF8FC,0xFEFF,0xFEFB,0xF7F1,0xE9E0,0xD6CA,0xBEB1,0xA394,0x8577,0x685A,0x4C3F,0x3227,0x1D15,0x0D08,0x0402,0x0000,0x0000,0x0000,0x0000,0x0000
E:   .dw 0x0102,0x050A,0x1019,0x222E,0x3A48,0x5666,0x7585,0x94A4,0xB2C0,0xCDD9,0xE4ED,0xF4F9,0xFDFF,0xFFFD,0xF8F3,0xEBE2,0xD7CB,0xBEAF,0xA191,0x8272,0x6253,0x4538,0x2B20,0x170F,0x0904,0x0200,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000
F:   .dw 0x0102,0x050B,0x121B,0x2633,0x4150,0x5F70,0x8091,0xA1B1,0xC0CE,0xDAE5,0xEEF5,0xFBFE,0xFFFE,0xFBF5,0xEEE4,0xD9CD,0xBFB0,0xA090,0x7F6F,0x5E4F,0x4032,0x261B,0x120A,0x0502,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000
FIS: .dw 0x0102,0x060C,0x141E,0x2B38,0x4858,0x697A,0x8C9D,0xAEBE,0xCDDA,0xE6EF,0xF7FC,0xFFFF,0xFDF8,0xF1E8,0xDDD0,0xC2B2,0xA291,0x7F6D,0x5C4C,0x3C2E,0x2117,0x0E07,0x0300,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000
G:   .dw 0x0102,0x060D,0x1622,0x2F3F,0x4F61,0x7386,0x99AB,0xBCCB,0xDAE6,0xF0F7,0xFCFF,0xFEFB,0xF6ED,0xE3D6,0xC7B7,0xA593,0x816E,0x5C4A,0x3A2B,0x1E13,0x0B05,0x0200,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000
GIS: .dw 0x0103,0x070F,0x1926,0x3545,0x586B,0x7E92,0xA5B8,0xC9D8,0xE5F0,0xF8FD,0xFFFE,0xFAF3,0xE9DD,0xCEBD,0xAB98,0x8571,0x5E4B,0x3A2A,0x1D12,0x0904,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000
A:   .dw 0x0103,0x0810,0x1C2A,0x3A4D,0x6175,0x8A9F,0xB3C5,0xD6E4,0xEFF8,0xFDFF,0xFDF8,0xF0E5,0xD7C6,0xB4A0,0x8B76,0x624E,0x3B2B,0x1C11,0x0803,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000
B:   .dw 0x0103,0x0912,0x1F2F,0x4155,0x6A80,0x97AC,0xC0D2,0xE2EE,0xF8FD,0xFFFD,0xF7ED,0xE1D1,0xBEAA,0x957F,0x6953,0x3F2D,0x1E11,0x0803,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000
H:   .dw 0x0103,0x0A14,0x2234,0x485E,0x758C,0xA3B9,0xCDDE,0xECF7,0xFDFF,0xFDF6,0xEBDD,0xCBB7,0xA18A,0x735C,0x4632,0x2113,0x0903,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000

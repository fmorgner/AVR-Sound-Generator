; Sinus Generator

.DEVICE atmega328p

.dseg
abFSIdx: .Byte 12       ; wave sample indices, each element points to a sample inside a different wave

.cseg

.org 0x0000
     rjmp    setup      ; register 'setup' as Programm Start Routine
.org OVF1addr
     rjmp    isr_timer1 ; register 'isr_timer1' as Timer1 Overflow Routine


; these should have be known in the environment, gavrasm doesn't know them
.def Y          = r28   ; Z for wordwise access
.def YL         = r28   ; Y low byte
.def YH         = r29   ; Y high byte
.def Z          = r30   ; Z for wordwise access
.def ZL         = r30   ; Z low byte
.def ZH         = r31   ; Z high byte

; names for the registers to help humans to understand
.def nNULL      = r16   ; a NULL - needed in 'reg > 15' because of the CPU 
.def rTemp      = r17   ; a temporary register
.def Zsave      = r18   ; backup to reset address Z                  (word)
.def ZLsave     = r18   ; backup to reset address Z to start of wave (low)
.def ZHsave     = r19   ;                                            (high)
.def nSmpIx     = r20   ; the index into the current wave for current step
.def nSmpVe     = r21   ; one byte sample value of a wave for current step
.def nSampleL   = r22   ; sum of current samples (low)
.def nSampleH   = r23   ;                        (high)
.def mInputVal  = r24   ; bitmask representing all input signals bitwise
.def mInputBit  = r25   ; bitmask representing one bit to ask from mInputVal

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
.equ    TPBH    = 0xfe  ; timer preset (high)
.equ    TPBL    = 0x24  ; timer preset (low)

; ==================================================
; SETUP INTERRUPT MECHANICS
; ones per program start
; ==================================================

    setup:

; setup interrupt generation

; here we use registers mainly without names 
; because they are used in short but many contexts

            cli                                     ; do not generate interrupts while setup phase

            ldi     rTemp,      low (RAMEND)        ; initializing stack pointer
            out     SPL,        rTemp               ; -- " --
            ldi     rTemp,      high(RAMEND)        ; -- " --
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

; PORTx operation definition values

            ldi     r16,        0x00                ; r16 to input mode for all pins
            ldi     r17,        0xFF                ; all pins to pullup / all pins to output

; define PORTC as input

            out     DDRC,       r16                 ; set input pins
            out     PORTC,      r17                 ; set pullup mode

; define PORTD and PORTB as output

            out     DDRD,       r17                 ; set output pins for PORTD
            ldi     r17,        0x0F                ; only the lower 4 bits to output on PORTB
            out     DDRB,       r17                 ; set output pins for PORTB

; from here on we will use register alias names as far as possible

; initialize a register with NULL for later use

            eor     nNULL,      nNULL               ; (r16) the NULL

; initialize all Frequency-Sample-Indices with "0"

            ldi     YL,         low (abFSIdx*2)     ; list of indices of next sample in wave
            ldi     YH,         high(abFSIdx*2)     ;   -- " --

            ldi     rTemp,      0x0C                ; 12 Tunes
    FSIdx:
            st      Y,          nNULL               ; 0 => abFSIdx[n]
            adiw    Y,          1                   ; next address (n++)
            dec     rTemp                           ; one done
            brne    FSIdx                           ; more to do?

            sei                                     ; setup is finished, allow generation of interrupts

; nothings to do but not ending the program
; interrupts will serve action provider

    wait:
            rjmp wait

; ==================================================
; START OF INTERRUPT SERVICE ROUTINE
; ==================================================

    isr_timer1:

; (re)adjust timer for next interrupt

            ldi     rTemp,      TPBH                ; [1]
            sts     TCNT1H,     rTemp               ; [2]
            ldi     rTemp,      TPBL                ; [1]
            sts     TCNT1L,     rTemp               ; [2]

; --------------------------------------------------
; initial address calculation
; --------------------------------------------------

; list of sample indices into the wave to Y

            ldi     YL,         low (abFSIdx*2)     ; [1] load Y to point to the start sample index array
            ldi     YH,         high(abFSIdx*2)     ; [1]

; start pointer of the wave to Z and to copy registers

            ldi     ZL,         low (abWaveSet*2)   ; [1] load Z to point to start of 2D wave matrix
            ldi     ZH,         high(abWaveSet*2)   ; [1]
            movw    Zsave,      Z                   ; [1] sometimes we need the startpoint again later on

; reset output value (sample sum)

            eor     nSampleL,   nSampleL            ; [1]
            eor     nSampleH,   nSampleH            ; [1]

; start on input pin 0

            ldi     mInputBit,  0x01                ; [1] starting the big loop
            ror     mInputBit                       ; [1] set carry flag

; --------------------------------------------------
; main loop: read in the input signal status
; --------------------------------------------------

    read:
            rol     mInputBit                       ; [1] the first bit loures in the carry flag
            sbrc    mInputBit,  0x06                ; [1,2] the last bit we are allowed to start a run
            rjmp    output                          ; [2]

            in      mInputVal,  PINC                ; [1] check whats ON
            and     mInputVal,  mInputBit           ; [1]
            breq    run                             ; [1,2] a bit is 0, so we have to make a run for it

            adiw    Y,          1                   ; [2] the next element of the frequence vector abFSIdx

            ldi     rTemp,      64                  ; [1] the next wave
            add     ZLsave,     rTemp               ; [1]
            adc     ZHsave,     nNULL               ; [1]

            rjmp    read                            ; [2] check the next pin/key

; add the current sample value of the current wave
; to the sum of current sample values

    run:

; load start address of the next wave

            movw    Z,          Zsave               ; [1] sometimes we need the start again later on

; add index of current 'sample in wave' pointer

            ld      nSmpIx,     Y                   ; [1] abFSIdx[n] => register nSmpIx
            add     ZL,         nSmpIx              ; [1] add nSmpIx to wave pointer &abWaveSet[abFSIdx[n]]
            adc     ZH,         nNULL               ; [1]

; get and check the next sample

    strt1:
            lpm                                     ; [3] load [Z] to r0 ( 'ld Z,r' does not work! )
            tst     r0                              ; [1] set the flag regarding to the content
            brne    next1                           ; [1,2] if not 0, we have the sample

            eor     r0,         r0                  ; [1] the assumed sample value is 2 - the average end value
            inc     r0                              ; [1]
            inc     r0                              ; [1]

; end of wave, restart the wave

            movw    Z,          Zsave               ; [1] reset Z to start of current wave to enable jump to the next wave

            mov     nSmpIx,     nNULL               ; [1] the sample pointer becomes 0 too to restart the current wave
            rjmp    next2                           ; [2] we must no increment our nSmpIx, because it is already correct

; make address of next 'sample in wave' pointer

    next1:
            inc     nSmpIx                          ; [1] next time the next sample
    next2:
            st      Y,          nSmpIx              ; [2] write back to abFSIdx

; adding the sample to the sum of samples

            add     nSampleL,   r0                  ; [1] accumulate all samples of all runs 
            adc     nSampleH,   nNULL               ; [1]

; test if all keys were checked

            sbrs    mInputBit,  0x05                ; [1,2] reached the last bit we will read?
            rjmp    read                            ; [2] no, so we go to the next step

; output sample value

; we expect maximum value of lower than 255*12=3060
; if we are using an external D/A converter
; this is 12 bit (0 to 4096) resolution

    output:
            out     PORTD,      nSampleL            ; [1] output result
            out     PORTB,      nSampleH            ; [1]
            reti                                    ; [4] close the book


abWaveSet:
;	little endian
;    === ===============================================================================================================================================================================================================================
C:   .dw 0x0201,0x0603,0x100B,0x1E16,0x2F26,0x4439,0x5B4F,0x7467,0x8C80,0xA599,0xBCB1,0xD1C7,0xE2DA,0xF0EA,0xFAF5,0xFEFD,0xFEFF,0xFAFD,0xF0F5,0xE2EA,0xD1DA,0xBCC7,0xA5B1,0x8C99,0x7480,0x5B67,0x444F,0x2F39,0x1E26,0x1016,0x060B,0x0003
CIS: .dw 0x0201,0x0704,0x120C,0x2119,0x352A,0x4B40,0x6458,0x7F71,0x998C,0xB2A6,0xC9BE,0xDDD4,0xEDE5,0xF8F3,0xFEFC,0xFFFF,0xFAFD,0xF0F5,0xE1E9,0xCDD7,0xB7C3,0x9EAB,0x8491,0x6A77,0x505D,0x3944,0x252F,0x151C,0x090E,0x0005,0x0000,0x0000
D:   .dw 0x0201,0x0804,0x140D,0x251C,0x3B2F,0x5347,0x6F61,0x8A7C,0xA698,0xBFB3,0xD6CB,0xE8E0,0xF6F0,0xFDFA,0xFFFF,0xFAFD,0xF0F6,0xE0E8,0xCBD6,0xB3C0,0x99A6,0x7D8B,0x616F,0x4754,0x2F3B,0x1C25,0x0D14,0x0408,0x0000,0x0000,0x0000,0x0000
DIS: .dw 0x0201,0x0904,0x160F,0x291F,0x4134,0x5C4E,0x796B,0x9788,0xB3A5,0xCDC0,0xE2D8,0xF2EB,0xFCF8,0xFFFE,0xFBFE,0xF1F7,0xE0E9,0xCAD6,0xB1BE,0x94A3,0x7785,0x5A68,0x3F4C,0x2732,0x151D,0x080D,0x0004,0x0000,0x0000,0x0000,0x0000,0x0000
E:   .dw 0x0201,0x0A05,0x1910,0x2E22,0x483A,0x6656,0x8575,0xA494,0xC0B2,0xD9CD,0xEDE4,0xF9F4,0xFFFD,0xFDFF,0xF3F8,0xE2EB,0xCBD7,0xAFBE,0x91A1,0x7282,0x5362,0x3845,0x202B,0x0F17,0x0409,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000
F:   .dw 0x0201,0x0B05,0x1B12,0x3326,0x5041,0x705F,0x9180,0xB1A1,0xCEC0,0xE5DA,0xF5EE,0xFEFB,0xFEFF,0xF5FB,0xE4EE,0xCDD9,0xB0BF,0x90A0,0x6F7F,0x4F5E,0x3240,0x1B26,0x0A12,0x0005,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000
FIS: .dw 0x0201,0x0C06,0x1E14,0x382B,0x5848,0x7A69,0x9D8C,0xBEAE,0xDACD,0xEFE6,0xFCF7,0xFFFF,0xF8FD,0xE8F1,0xD0DD,0xB2C2,0x91A2,0x6D7F,0x4C5C,0x2E3C,0x1721,0x070E,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000
G:   .dw 0x0201,0x0D06,0x2216,0x3F2F,0x614F,0x8673,0xAB99,0xCBBC,0xE6DA,0xF7F0,0xFFFC,0xFBFE,0xEDF6,0xD6E3,0xB7C7,0x93A5,0x6E81,0x4A5C,0x2B3A,0x131E,0x050B,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000
GIS: .dw 0x0301,0x0F07,0x2619,0x4535,0x6B58,0x927E,0xB8A5,0xD8C9,0xF0E5,0xFDF8,0xFEFF,0xF3FA,0xDDE9,0xBDCE,0x98AB,0x7185,0x4B5E,0x2A3A,0x121D,0x0009,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000
A:   .dw 0x0301,0x1008,0x2A1C,0x4D3A,0x7561,0x9F8A,0xC5B3,0xE4D6,0xF8EF,0xFFFD,0xF8FD,0xE5F0,0xC6D7,0xA0B4,0x768B,0x4E62,0x2B3B,0x111C,0x0008,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000
B:   .dw 0x0301,0x1209,0x2F1F,0x5541,0x806A,0xAC97,0xD2C0,0xEEE2,0xFDF8,0xFDFF,0xEDF7,0xD1E1,0xAABE,0x7F95,0x5369,0x2D3F,0x111E,0x0008,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000
H:   .dw 0x0301,0x140A,0x3422,0x5E48,0x8C75,0xB9A3,0xDECD,0xF7EC,0xFFFD,0xF6FD,0xDDEB,0xB7CB,0x8AA1,0x5C73,0x3246,0x1321,0x0009,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000

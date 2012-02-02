; Wave Generator

;.DEVICE atmega328p
.DEVICE atmega324p 

.dseg
abFSIdx:   .Byte 12        ; wave sample indices, each element points to a sample inside a different wave
abWave:    .Byte 64*12

.cseg

.org 0x0000
     rjmp    setup       ; register 'setup' as Programm Start Routine
.org OVF1addr
     rjmp    isr_timer1  ; register 'isr_timer1' as Timer1 Overflow Routine


; these should have be known in the environment, gavrasm doesn't know them
.def Y           = r28   ; Z for wordwise access
.def YL          = r28   ; Y low byte
.def YH          = r29   ; Y high byte
.def Z           = r30   ; Z for wordwise access
.def ZL          = r30   ; Z low byte
.def ZH          = r31   ; Z high byte

.equ nBitsLimit  = 13    ; we assume to be albe to play 12 tones in parallel
.equ ioInputL    = PINB  ; 8 bits
.equ ioInputH    = PIND  ; 4 bits
.equ ioOutputL   = PORTC ; 
.equ ioOutputH   = PORTA ; 

; names for the registers to help humans to understand
.def fInputHigh  = r13   ; flag if to read from LOW or HIGH port
.def nBits       = r14   ; counter to count tones played in parallel
.def nWaveLen    = r15   ; the length in bytes of a wave
.def nNULL       = r16   ; a NULL - needed in 'reg > 15' because of the CPU 
.def rTemp       = r17   ; a temporary register
.def Zsave       = r18   ; backup to reset address Z                  (word)
.def ZLsave      = r18   ; backup to reset address Z to start of wave (low)
.def ZHsave      = r19   ;                                            (high)
.def nSmpIx      = r20   ; the index into the current wave for current step
.def nSmpVe      = r21   ; one byte sample value of a wave for current step
.def nSampleL    = r22   ; sum of current samples (low)
.def nSampleH    = r23   ;                        (high)
.def mInputVal   = r24   ; bitmask representing all input signals bitwise
.def mInputBit   = r25   ; bitmask representing one bit to ask from input Port

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
;.equ    TPBH    = 0xfe  ; timer preset (high)
;.equ    TPBL    = 0x24  ; timer preset (low)

.equ    TPBH    = 0xfd  ; timer preset (high)
.equ    TPBL    = 0xbb  ; timer preset (low)


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
            ldi     r17,        0xFF                ; all pins to pullup / all pins to outtput

; define PORTC as input

            out     DDRB,       r16                 ; set input pins
            out     PORTB,      r17                 ; set pullup mode
            out     DDRD,       r16                 ; set input pins
            out     PORTD,      r17                 ; set pullup mode

; define PORTD and PORTB as output

            out     DDRC,       r17                 ; set output pins for PORTC
            ldi     r17,        0x0F                ; only the lower 4 bits to output on PORTA
            out     DDRA,       r17                 ; set output pins for PORTA

; from here on we will use register alias names as far as possible

; initialize a register with NULL for later use

            ldi     rTemp,      64                  ; (r17) jump distance to the next wave
            mov     nWaveLen,   rTemp               ; (r15) set it to register / no ldi for r15
            clr     nNULL                           ; (r16) the NULL

; initialize all Frequency-Sample-Indices with "0"

            ldi     YL,         low (abFSIdx*2)     ; list of indices of next sample in wave
            ldi     YH,         high(abFSIdx*2)     ;   -- " --

            ldi     rTemp,      0x0C                ; 12 Tunes
    FSIdx:
            st      Y+,         nNULL               ; 0 => abFSIdx[n]
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

            ldi     rTemp,      TPBH                ; [1] first the high byte to miminize random impact
            sts     TCNT1H,     rTemp               ; [2] by overflow of low byte (we cant be sure which
            ldi     rTemp,      TPBL                ; [1] value low byte becomes, but the interrupt timer
            sts     TCNT1L,     rTemp               ; [2] 00:00 while entering the service routine)

; output of last sum of samples

            out     ioOutputL,  nSampleL            ; [1] output result of last operation to output ports
            out     ioOutputH,  nSampleH            ; [1] here to guarantee contant timing of output signal

; reset output value

            clr     nSampleL                        ; [1] clear sum of sample values before start of any
            clr     nSampleH                        ; [1] other action for summing up the a samples sum

; initialize counter for parallel tones

            ldi     rTemp, nBitsLimit               ; [1] initialize counter for parallel active tones
            mov     nBits, rTemp                    ; [1] with amount of maximum parallel playable tones

            clr     fInputHigh                      ; we start reading the LOW port

; --------------------------------------------------
; initial address calculation
; --------------------------------------------------

; list of sample indices into the wave to Y

            ldi     YL,         low (abFSIdx*2)     ; [1] load Y to point to the start sample index array
            ldi     YH,         high(abFSIdx*2)     ; [1] 

; start pointer wave to Z and copy to save registers

            ldi     ZL,         low (abWaveSet*2)   ; [1] load Z to point to start of 2D wave matrix
            ldi     ZH,         high(abWaveSet*2)   ; [1]
            movw    Zsave,      Z                   ; [1] each round we need the startpoint again

; start on input pin 0

            ldi     mInputBit,  0x01                ; [1] starting the big loop
            ror     mInputBit                       ; [1] set carry flag for first command in loop

; --------------------------------------------------
; main loop: interprete input signal status
; --------------------------------------------------

    main:

            dec     nBits                           ; [1] next round, if 0, we are done
            breq    isr_end                         ; [1,2] all keys tested, end of ISR

            rol     mInputBit                       ; [1] the first bit loures in the carry flag
            brcc    start_query                     ; [1,2] our bit was not overflown

; this point will be reached after 8 bits were tested

            rol     mInputBit                       ; [1] the first bit loures in the carry flag again
            mov     fInputHigh,  mInputBit          ; [1] mInputBit now is 0x01, we use it here as 0x01

    start_query:

; call sample index

            ld      nSmpIx,     Y                   ; [1] abFSIdx[n] => register nSmpIx

; if wave not finalized, play it anyway

            tst     nSmpIx                          ; [1] Non-zero if ave if not finished yet
            brne    run                             ; [1,2] let us finish the wave first

; query external input

            tst     fInputHigh                      ; [1] do we have to as the HIGH port?
            breq    input_low                       ; [1] no, then proceed with the LOW port

; query the HIGH port

            in      mInputVal, ioInputH             ; [1] get the HIGH port input mask
            and     mInputVal, mInputBit            ; [1] combine with the bit selection mask
            breq    run                             ; [1,2] key pressed, we have to add the current tone
            rjmp    next_wave                       ; [2] we won't ask the LOW port anymore

; query the LOW port

    input_low:

            in      mInputVal, ioInputL             ; [1] get the LOW port input mask
            and     mInputVal, mInputBit            ; [1] combine with the bit selection mask
            breq    run                             ; [1,2] key pressed, we have to add the current tone

    next_wave:

            adiw    Y,          1                   ; [2] the next element of the sample index vector

            add     ZLsave,     nWaveLen            ; [1] calculate the address of the next wave
            adc     ZHsave,     nNULL               ; [1] add the carry flag if set

            rjmp    main                            ; [2] check the next pin/key

; add the current sample value of the current wave
; to the sum of current sample values

    run:

; calculate address of current sample in current wave

            movw    Z,          Zsave               ; [1] load the current wave pointer
            add     ZL,         nSmpIx              ; [1] add nSmpIx to wave pointer &abWaveSet[abFSIdx[n]]
            adc     ZH,         nNULL               ; [1]

; get and check current sample sample

            lpm     rTemp,      Z                   ; [3] load [Z] from CSEG to register
            tst     rTemp                           ; [1] set the flag regarding to the content
            brne    next                            ; [1,2] if not 0, we have a sample

; end of wave, no immediate value present

            ldi     rTemp,      0x02                ; [1] the assumed sample value is 2 = the average end value

; end of wave, restart the wave

            clr     nSmpIx                          ; [1] the sample pointer becomes 0 too to restart the current wave
            rjmp    next_wo_inc                     ; [2] we must no increment our nSmpIx, because it is already correct

; make address of next 'sample in wave' pointer

    next:
            inc     nSmpIx                          ; [1] next time the next sample

    next_wo_inc:

            st      Y,          nSmpIx              ; [2] write back to abFSIdx

; adding the sample to the sum of samples

            add     nSampleL,   rTemp               ; [1] accumulate all samples of all runs 
            adc     nSampleH,   nNULL               ; [1]

            rjmp    next_wave                       ; [2] no, so we go to the next step

; output sample value

; we expect maximum value of lower than 255*12=3060
; if we are using an external D/A converter
; this is 12 bit (0 to 4096) resolution

    isr_end:
            reti                                    ; [4] close the book


abWaveSet:
;	little endian waves
;    === ===============================================================================================================================================================================================================================
C:   .dw 0x0301,0x0905,0x130D,0x221A,0x342B,0x4A3F,0x6155,0x7A6D,0x9386,0xAB9F,0xC1B6,0xD5CC,0xE6DE,0xF3ED,0xFBF7,0xFFFD,0xFDFF,0xF7FB,0xEDF3,0xDEE6,0xCCD5,0xB6C1,0x9FAB,0x8693,0x6D7A,0x5561,0x3F4A,0x2B34,0x1A22,0x0D13,0x0509,0x0003
CIS: .dw 0x0301,0x0905,0x150F,0x261D,0x3A30,0x5246,0x6B5E,0x8578,0x9F92,0xB8AC,0xCEC4,0xE1D8,0xF0E9,0xFAF6,0xFEFD,0xFEFF,0xF7FB,0xECF2,0xDCE5,0xC8D2,0xB1BD,0x98A4,0x7D8B,0x6370,0x4A57,0x343F,0x212A,0x1118,0x070C,0x0004,0x0000,0x0000
D:   .dw 0x0301,0x0B06,0x1810,0x2A20,0x4135,0x5A4D,0x7568,0x9183,0xAC9F,0xC5B9,0xDBD1,0xECE4,0xF8F3,0xFEFC,0xFEFF,0xF8FC,0xECF3,0xDBE4,0xC5D1,0xADB9,0x929F,0x7684,0x5A68,0x414D,0x2A35,0x1821,0x0B11,0x0306,0x0000,0x0000,0x0000,0x0000
DIS: .dw 0x0301,0x0C07,0x1A12,0x2F24,0x483B,0x6355,0x8172,0x9E8F,0xBAAC,0xD2C6,0xE6DD,0xF5EE,0xFDFA,0xFEFF,0xF9FD,0xEDF4,0xDBE5,0xC4D0,0xAAB7,0x8D9B,0x6F7E,0x5361,0x3845,0x222D,0x1119,0x060B,0x0003,0x0000,0x0000,0x0000,0x0000,0x0000
E:   .dw 0x0301,0x0D07,0x1D14,0x3428,0x4F41,0x6D5E,0x8D7D,0xAB9C,0xC7B9,0xDED3,0xF0E8,0xFBF7,0xFFFE,0xFAFE,0xEFF6,0xDCE6,0xC4D1,0xA8B7,0x8999,0x6A7A,0x4C5B,0x313E,0x1B26,0x0C13,0x0306,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000
F:   .dw 0x0402,0x0E08,0x2117,0x3A2D,0x5748,0x7867,0x9989,0xB8A9,0xD4C7,0xEAE0,0xF8F2,0xFEFC,0xFCFE,0xF1F8,0xDFE9,0xC6D3,0xA8B8,0x8898,0x6777,0x4757,0x2C39,0x1620,0x080E,0x0004,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000
FIS: .dw 0x0402,0x1009,0x2419,0x4031,0x6050,0x8372,0xA695,0xC6B6,0xE0D4,0xF3EA,0xFDF9,0xFEFF,0xF5FA,0xE3ED,0xC9D7,0xAABA,0x8899,0x6576,0x4454,0x2835,0x121C,0x050A,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000
G:   .dw 0x0402,0x120A,0x291C,0x4737,0x6A58,0x8F7D,0xB3A2,0xD2C4,0xEBE0,0xFAF4,0xFFFE,0xF8FD,0xE8F1,0xCEDC,0xAEBF,0x8A9C,0x6577,0x4253,0x2533,0x0F19,0x0308,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000
GIS: .dw 0x0502,0x140B,0x2D1F,0x4E3D,0x7561,0x9C88,0xC0AF,0xDFD0,0xF4EB,0xFEFA,0xFCFE,0xEEF6,0xD5E3,0xB4C6,0x8FA2,0x677B,0x4254,0x2332,0x0D17,0x0006,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000
A:   .dw 0x0502,0x160C,0x3223,0x5744,0x806B,0xA995,0xCDBC,0xEADD,0xFBF4,0xFEFE,0xF4FB,0xDEEA,0xBDCE,0x96AA,0x6C81,0x4558,0x2433,0x0D17,0x0006,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000
AIS: .dw 0x0602,0x180D,0x3827,0x604B,0x8B75,0xB6A1,0xDAC9,0xF3E8,0xFEFA,0xFAFE,0xE7F2,0xC8D9,0xA0B4,0x748A,0x495E,0x2536,0x0D17,0x0005,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000
H:   .dw 0x0602,0x1B0F,0x3E2B,0x6953,0x9881,0xC3AE,0xE5D6,0xFAF2,0xFEFE,0xF1F9,0xD4E4,0xACC1,0x7E96,0x5167,0x293C,0x0E1A,0x0006,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000

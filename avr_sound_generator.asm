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
            cpi     rTemp,      0xFF                ; [1] fi 0xff, the wave has its last entry: 0
            brne    next                            ; [1,2] if not 0, we have a sample

; end of wave, no immediate value present

            clr     rTemp                           ; [1] the average last sample value is 0

; end of wave, restart the wave

            clr     nSmpIx                          ; [1] the sample pointer becomes 0 too, to restart the current wave
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
C:   .dw 0x0200,0x0804,0x120C,0x2119,0x342A,0x493E,0x6054,0x796D,0x9285,0xAA9E,0xC1B6,0xD5CB,0xE5DD,0xF2EC,0xFAF7,0xFEFD,0xFDFE,0xF7FA,0xECF2,0xDDE5,0xCBD5,0xB6C1,0x9EAA,0x8592,0x6D79,0x5460,0x3E49,0x2A34,0x1921,0x0C12,0x0408,0xFF02
CIS: .dw 0x0200,0x0804,0x140E,0x251C,0x392F,0x5145,0x6A5D,0x8477,0x9F92,0xB7AB,0xCEC3,0xE1D8,0xEFE9,0xF9F5,0xFEFC,0xFDFE,0xF7FB,0xEBF2,0xDBE4,0xC7D2,0xB0BC,0x97A4,0x7D8A,0x626F,0x4A56,0x333E,0x2029,0x1017,0x060B,0xFF03,0xFFFF,0xFFFF
D:   .dw 0x0200,0x0A05,0x170F,0x291F,0x4034,0x594C,0x7567,0x9183,0xAC9E,0xC5B8,0xDAD0,0xEBE3,0xF7F2,0xFDFB,0xFDFE,0xF7FB,0xEBF2,0xDAE4,0xC5D0,0xACB9,0x919F,0x7583,0x5967,0x404C,0x2934,0x1720,0x0A10,0x0205,0xFFFF,0xFFFF,0xFFFF,0xFFFF
DIS: .dw 0x0200,0x0B06,0x1A11,0x2E23,0x473A,0x6254,0x8071,0x9D8F,0xB9AB,0xD2C6,0xE6DC,0xF4EE,0xFCF9,0xFEFE,0xF8FC,0xECF3,0xDAE4,0xC3CF,0xA9B7,0x8C9B,0x6E7D,0x5260,0x3844,0x212C,0x1018,0x050A,0xFF02,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF
E:   .dw 0x0200,0x0C06,0x1D13,0x3327,0x4E40,0x6C5D,0x8C7C,0xAA9B,0xC6B9,0xDED3,0xF0E8,0xFBF6,0xFEFD,0xFAFD,0xEEF5,0xDCE6,0xC4D0,0xA7B6,0x8998,0x6979,0x4B5A,0x313D,0x1B25,0x0B12,0x0205,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF
F:   .dw 0x0301,0x0D07,0x2016,0x392C,0x5747,0x7767,0x9888,0xB8A8,0xD3C6,0xE9DF,0xF8F1,0xFEFC,0xFCFE,0xF1F7,0xDEE8,0xC5D2,0xA7B7,0x8797,0x6676,0x4656,0x2B38,0x151F,0x070D,0xFF03,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF
FIS: .dw 0x0301,0x0F08,0x2418,0x3F31,0x604F,0x8271,0xA594,0xC5B6,0xDFD3,0xF2EA,0xFDF9,0xFDFE,0xF4FA,0xE2EC,0xC9D6,0xA9BA,0x8798,0x6475,0x4353,0x2734,0x111B,0x0409,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF
G:   .dw 0x0301,0x1109,0x281B,0x4636,0x6957,0x8E7C,0xB2A1,0xD2C3,0xEADF,0xF9F3,0xFEFD,0xF8FC,0xE7F1,0xCEDB,0xADBE,0x899C,0x6477,0x4152,0x2432,0x0E18,0x0207,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF
GIS: .dw 0x0401,0x130A,0x2C1E,0x4E3C,0x7460,0x9B88,0xC0AE,0xDED0,0xF3EA,0xFDFA,0xFBFE,0xEDF6,0xD5E2,0xB4C5,0x8EA1,0x667A,0x4153,0x2231,0x0C16,0xFF05,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF
A:   .dw 0x0401,0x150B,0x3122,0x5643,0x7F6A,0xA894,0xCDBB,0xE9DC,0xFAF3,0xFEFD,0xF4FA,0xDDEA,0xBCCE,0x95A9,0x6B80,0x4457,0x2332,0x0C16,0xFF05,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF
AIS: .dw 0x0501,0x180C,0x3726,0x5F4A,0x8B75,0xB5A1,0xD9C8,0xF2E7,0xFEFA,0xF9FD,0xE6F2,0xC7D8,0x9FB4,0x7389,0x485D,0x2435,0x0C16,0xFF04,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF
H:   .dw 0x0501,0x1A0E,0x3D2A,0x6852,0x9780,0xC3AE,0xE5D5,0xF9F1,0xFDFD,0xF0F9,0xD3E3,0xABC1,0x7D95,0x5066,0x283B,0x0D19,0xFF05,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF

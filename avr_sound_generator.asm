; Wave Generator

.DEVICE atmega324p 

.dseg
abFSIdx:   .Byte 16        ; wave sample indices, each element points to a sample inside a different wave
abWave:    .Byte 64*16     ; space for the current wave set (for future use)

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

.equ nBitsLimit  = 17    ; we assume to be able to play 16 tones in parallel
.equ ioInputL    = PINB  ; 8 bits
.equ ioInputH    = PIND  ; 4 bits
.equ ioOutputL   = PORTC ; 
.equ ioOutputH   = PORTA ; 

; names for the registers to help humans to understand
.def count1      = r10   ; generic counter 1
.def count2      = r11   ; generic counter 2
.def nWaveLen    = r12   ; the length in bytes of a wave
.def nWaveCount  = r13   ; amount of waves
.def fInputHigh  = r14   ; flag if to read from LOW or HIGH port
.def nBits       = r15   ; counter to count tones played in parallel
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

;  C5	*   523.25 Hz
;CIS5	*   554.37 Hz
;  D5	*   587.33 Hz
;DIS5	*   622.25 Hz
;  E5	*   659.26 Hz
;  F5	*   698.46 Hz
;FIS5	*   739.99 Hz
;  G5	*   783.99 Hz
;GIS5	*   830.61 Hz
;  A5	*   880.00 Hz
;  B5	*   932.33 Hz
;  H5	*   987.77 Hz
;  C6	* 1'046.50 Hz
;CIS6	* 1'108.73 Hz
;  D6	* 1'174.66 Hz
;DIS6	* 1'244.51 Hz

; Interrupt Generator has to be adjusted to 64*'C' = 33488 Hz
; The value is the start value for a timer counting with constant speed until
; initial value becomes full (0xFFFF). Which means: the higher the CPU frequency
; the lower the initial value has to be, the more precise the value can be
; adjusted

; 2 byte timing, here with value 0xFE24 (16MHz)
;.equ    TPBH    = 0xfe  ; timer preset (high)
;.equ    TPBL    = 0x24  ; timer preset (low)

; 2 bytes timing, here with value 0xFDBB (20MHz)
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

            ldi     rTemp,      16                  ; jump distance to the next wave
            mov     nWaveCount, rTemp               ; set it to register / no ldi for r15
            ldi     rTemp,      64                  ; jump distance to the next wave
            mov     nWaveLen,   rTemp               ; set it to register / no ldi for r15
            clr     nNULL                           ; the NULL

            rcall   WaveSet2RAM                     ; copy wave set from FLASH to RAM

; initialize all Frequency-Sample-Indices with "0"

            ldi     YL,         low (abFSIdx)       ; list of indices of next sample in wave
            ldi     YH,         high(abFSIdx)       ;   -- " --

            ldi     rTemp,      nWaveCount          ; 12 Tones
    FSIdx:
            st      Y+,         nNULL               ; 0 => abFSIdx[n]
            dec     rTemp                           ; one done
            brne    FSIdx                           ; more to do?

            sei                                     ; setup is finished, allow generation of interrupts

; nothings to do but not ending the program
; interrupts will serve action provider

    wait:
            rjmp wait

; here we copy the current waveset to RAM

    WaveSet2RAM:
            ldi     ZL,         low (abWaveSet01*2) ; [1] wave set in FLASH
            ldi     ZH,         high(abWaveSet01*2) ; [1]   -- " --

            ldi     YL,         low (abWave)        ; [1] wave set in RAM
            ldi     YH,         high(abWave)        ; [1]   -- " --
    MoveWSet:
            mov     count1,     nWaveCount          ; [1] amount of waves to copy
    MoveWave:
            mov     count2,     nWaveLen            ; [1] amount of bytes per wave to copy
    MoveByte:
            lpm     rTemp, Z+                       ; [3] read a byte from FLASH
            st      Y+, rTemp                       ; [2] write the byte to SRAM

            dec     count2                          ; [1] one sample down
            brne    MoveByte                        ; [1,2] if not NULL the wave is not yet copied

            dec     count1                          ; [1] one wave down
            brne    MoveWave                        ; [1,2] if not NULL, we have to go again

            ret                                     ; [4] return bhind calling point

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

            clr     fInputHigh                      ; [1] we start reading the LOW port

; --------------------------------------------------
; initial address calculation
; --------------------------------------------------

; list of sample indices into the wave to Y

            ldi     YL,         low (abFSIdx)       ; [1] load Y to point to the start sample index array
            ldi     YH,         high(abFSIdx)       ; [1] 

; start pointer wave to Z and copy to save registers

            ldi     ZL,         low (abWave)        ; [1] load Z to point to start of 2D wave matrix
            ldi     ZH,         high(abWave)        ; [1] 
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
            breq    input_low                       ; [1,2] no, then proceed with the LOW port

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

            ld      rTemp,      Z                   ; [1] load [Z] from DSEG to register
            cpi     rTemp,      0xFF                ; [1] if 0xff, its the last entry of the wave
            brne    next                            ; [1,2] if not 0, we have a valid sample

; end of wave, no immediate value present

            clr     rTemp                           ; [1] the average last sample value is 0

; end of wave, restart the wave

            ldi     nSmpIx,     -1                  ; [1] the sample pointer becomes 0 too (next cmd) = restart the wave 

; make address of next 'sample in wave' pointer

    next:
            inc     nSmpIx                          ; [1] next time the next sample
            st      Y,          nSmpIx              ; [2] write back to abFSIdx

; adding the sample to the sum of samples

            add     nSampleL,   rTemp               ; [1] accumulate all samples of all runs 
            adc     nSampleH,   nNULL               ; [1] add carry flag to high byte

            rjmp    next_wave                       ; [2] we go to the next step

; output sample value

; we expect maximum value of lower than 255*12=3060
; if we are using an external D/A converter
; this is 12 bit (0 to 4096) resolution

    isr_end:
            reti                                    ; [4] close the book (the result value is not yet used!)


abWaveSet01:
;	  little endian waves

;         Violine wave
;     === ===============================================================================================================================================================================================================================
;V1:  .dw 0x1E09,0x3B2F,0x3C45,0x2A31,0x1B23,0x140F,0x291C,0x493A,0x6356,0x6F6B,0x7573,0x7576,0x7472,0x6F72,0x7370,0x7775,0x7074,0x6E6C,0x7972,0x9284,0xAFA5,0xB3B8,0xA0AD,0x8C98,0xB09F,0xE1CB,0xFEF4,0xDEF2,0x86B5,0xA07B,0x80C0,0xFF40
;V2:  .dw 0x1B0A,0x4233,0x393E,0x1C27,0x1511,0x261D,0x5948,0x706A,0x7776,0x7478,0x7573,0x7374,0x7370,0x7877,0x6F75,0x726E,0x9A87,0xB4AA,0xB5B9,0x9BAE,0x918E,0xC49E,0xFEEC,0xC2DF,0x86A7,0x847C,0xAF93,0xC0BE,0x8CB3,0x3A6E,0x0F23,0xFF06

;         Sinus waves + harmonics
;      === ===============================================================================================================================================================================================================================
C5:   .dw 0x0F02,0x1415,0x2618,0x4734,0x9569,0xCAB7,0xE6D9,0xE9EA,0xFCF0,0xF3FE,0xE2E8,0xD4DB,0xE9DB,0xE3EE,0xC9D6,0x9FB5,0x9395,0x7A8B,0x686D,0x6464,0x8B73,0x9A9A,0x9296,0x7385,0x6A6B,0x495F,0x2835,0x111B,0x2415,0x242A,0x161C,0xFF0C	
CIS5: .dw 0x0F11,0x1416,0x2A1C,0x553B,0xAA7F,0xD4C4,0xEAE3,0xEFE9,0xFEFB,0xE7F1,0xD8E1,0xE1D5,0xE9ED,0xCEDC,0xA4BC,0x9396,0x7A8C,0x676D,0x6664,0x927A,0x989B,0x8B94,0x6D79,0x626A,0x374C,0x1A28,0x1810,0x2926,0x1A21,0xFF12,0xFFFF,0xFFFF	
D5:   .dw 0x1011,0x1516,0x301F,0x6743,0xBB96,0xDFCE,0xE9E9,0xFAEE,0xF0FE,0xDFE7,0xD7D7,0xEEE5,0xD5E3,0xADC4,0x9499,0x7C8E,0x676E,0x6864,0x967F,0x979A,0x8391,0x6B71,0x5366,0x2A3B,0x101C,0x2718,0x1F28,0x0F18,0xFFFF,0xFFFF,0xFFFF,0xFFFF	
DIS5: .dw 0x1012,0x1715,0x3623,0x7C4E,0xC6AB,0xE6DA,0xECEA,0xFEF8,0xE7F0,0xD5DF,0xE8DB,0xDDEC,0xBACE,0x959F,0x8190,0x6770,0x6865,0x9780,0x9799,0x7C8E,0x696E,0x445E,0x2030,0x1712,0x2925,0x171F,0xFF0D,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF	
E5:   .dw 0x1113,0x1A14,0x3C27,0x915F,0xD1BC,0xEBE2,0xF6EA,0xF1FE,0xDEE7,0xDDD5,0xE8EB,0xC5D9,0x99AD,0x8992,0x6974,0x6666,0x977E,0x9699,0x778B,0x666D,0x3B54,0x1826,0x2013,0x212A,0x0E18,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF	
F5:   .dw 0x1214,0x1D14,0x442D,0xA773,0xDDC6,0xE8E8,0xFDF4,0xE9F3,0xD4DE,0xECDF,0xD5E4,0xA2BF,0x8F96,0x6E7B,0x6466,0x947A,0x9799,0x758B,0x646C,0x344A,0x1121,0x281A,0x1C23,0xFF11,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF	
FIS5: .dw 0x1315,0x1F13,0x5034,0xB986,0xE2D2,0xF0EA,0xF7FA,0xDEEB,0xE0D5,0xE1ED,0xB8D0,0x929B,0x7389,0x6566,0x8C72,0x9899,0x758B,0x636C,0x2E46,0x121D,0x2A1E,0x1320,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF	
G5:   .dw 0x1415,0x2115,0x633B,0xC39A,0xEADE,0xF6EA,0xEDFC,0xD6DE,0xECE0,0xCBDF,0x9AB2,0x7E8F,0x676F,0x8267,0x999A,0x788C,0x626D,0x2B44,0x161B,0x2522,0x101D,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF	
GIS5: .dw 0x1516,0x2417,0x7641,0xD0B1,0xE9E1,0xFDF5,0xE0EF,0xE0D8,0xDEEC,0xACC7,0x8E99,0x6776,0x7766,0x9793,0x8090,0x6370,0x2B46,0x191A,0x2125,0xFF17,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF	
A5:   .dw 0x1616,0x2A1B,0x874B,0xDDBE,0xEEEA,0xF2F7,0xDCE5,0xEADF,0xC5DF,0x97A8,0x748B,0x6665,0x9981,0x8899,0x6471,0x304C,0x191C,0x2125,0xFF13,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF	
AIS5: .dw 0x1617,0x321E,0x9B5C,0xDFC8,0xF6E9,0xEDFB,0xDBDE,0xDFE6,0xA6C6,0x8795,0x6772,0x8D71,0x8C97,0x6A78,0x3A59,0x181F,0x2123,0xFF12,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF	
H5:   .dw 0x1517,0x3A20,0xB170,0xE8D8,0xF8F0,0xDDEF,0xE2D6,0xC8E1,0x94A8,0x6F83,0x7B68,0x9A97,0x7288,0x4261,0x1422,0x211E,0xFF13,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF	
C6:   .dw 0x1417,0x4120,0xBE7F,0xEADE,0xF6F5,0xD9E6,0xE6E2,0xACCF,0x8294,0x676C,0x977F,0x7D93,0x536A,0x1830,0x251D,0xFF19,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF	
CIS6: .dw 0x1416,0x4A21,0xC98E,0xEFE1,0xF0F7,0xE1DE,0xD8E9,0x97B2,0x6A82,0x8167,0x8A96,0x6074,0x2043,0x251B,0xFF21,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF	
D6:   .dw 0x1416,0x5A24,0xD9A3,0xF6EA,0xE0F5,0xE3D9,0xB9DE,0x859C,0x686C,0x9783,0x7487,0x375B,0x1C1A,0x0F21,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF	
DIS6: .dw 0x1616,0x6D2B,0xDDB5,0xF4EC,0xDDF0,0xE1E2,0xA1BE,0x6F88,0x8469,0x8599,0x4F6F,0x1A25,0x1F23,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF	

;         Sinus waves
;     === ===============================================================================================================================================================================================================================
C:    .dw 0x0200,0x0804,0x120C,0x2119,0x342A,0x493E,0x6054,0x796D,0x9285,0xAA9E,0xC1B6,0xD5CB,0xE5DD,0xF2EC,0xFAF7,0xFEFD,0xFDFE,0xF7FA,0xECF2,0xDDE5,0xCBD5,0xB6C1,0x9EAA,0x8592,0x6D79,0x5460,0x3E49,0x2A34,0x1921,0x0C12,0x0408,0xFF02
CIS:  .dw 0x0200,0x0804,0x140E,0x251C,0x392F,0x5145,0x6A5D,0x8477,0x9F92,0xB7AB,0xCEC3,0xE1D8,0xEFE9,0xF9F5,0xFEFC,0xFDFE,0xF7FB,0xEBF2,0xDBE4,0xC7D2,0xB0BC,0x97A4,0x7D8A,0x626F,0x4A56,0x333E,0x2029,0x1017,0x060B,0xFF03,0xFFFF,0xFFFF
D:    .dw 0x0200,0x0A05,0x170F,0x291F,0x4034,0x594C,0x7567,0x9183,0xAC9E,0xC5B8,0xDAD0,0xEBE3,0xF7F2,0xFDFB,0xFDFE,0xF7FB,0xEBF2,0xDAE4,0xC5D0,0xACB9,0x919F,0x7583,0x5967,0x404C,0x2934,0x1720,0x0A10,0x0205,0xFFFF,0xFFFF,0xFFFF,0xFFFF
DIS:  .dw 0x0200,0x0B06,0x1A11,0x2E23,0x473A,0x6254,0x8071,0x9D8F,0xB9AB,0xD2C6,0xE6DC,0xF4EE,0xFCF9,0xFEFE,0xF8FC,0xECF3,0xDAE4,0xC3CF,0xA9B7,0x8C9B,0x6E7D,0x5260,0x3844,0x212C,0x1018,0x050A,0xFF02,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF
E:    .dw 0x0200,0x0C06,0x1D13,0x3327,0x4E40,0x6C5D,0x8C7C,0xAA9B,0xC6B9,0xDED3,0xF0E8,0xFBF6,0xFEFD,0xFAFD,0xEEF5,0xDCE6,0xC4D0,0xA7B6,0x8998,0x6979,0x4B5A,0x313D,0x1B25,0x0B12,0x0205,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF
F:    .dw 0x0301,0x0D07,0x2016,0x392C,0x5747,0x7767,0x9888,0xB8A8,0xD3C6,0xE9DF,0xF8F1,0xFEFC,0xFCFE,0xF1F7,0xDEE8,0xC5D2,0xA7B7,0x8797,0x6676,0x4656,0x2B38,0x151F,0x070D,0xFF03,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF
FIS:  .dw 0x0301,0x0F08,0x2418,0x3F31,0x604F,0x8271,0xA594,0xC5B6,0xDFD3,0xF2EA,0xFDF9,0xFDFE,0xF4FA,0xE2EC,0xC9D6,0xA9BA,0x8798,0x6475,0x4353,0x2734,0x111B,0x0409,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF
G:    .dw 0x0301,0x1109,0x281B,0x4636,0x6957,0x8E7C,0xB2A1,0xD2C3,0xEADF,0xF9F3,0xFEFD,0xF8FC,0xE7F1,0xCEDB,0xADBE,0x899C,0x6477,0x4152,0x2432,0x0E18,0x0207,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF
GIS:  .dw 0x0401,0x130A,0x2C1E,0x4E3C,0x7460,0x9B88,0xC0AE,0xDED0,0xF3EA,0xFDFA,0xFBFE,0xEDF6,0xD5E2,0xB4C5,0x8EA1,0x667A,0x4153,0x2231,0x0C16,0xFF05,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF
A:    .dw 0x0401,0x150B,0x3122,0x5643,0x7F6A,0xA894,0xCDBB,0xE9DC,0xFAF3,0xFEFD,0xF4FA,0xDDEA,0xBCCE,0x95A9,0x6B80,0x4457,0x2332,0x0C16,0xFF05,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF
AIS:  .dw 0x0501,0x180C,0x3726,0x5F4A,0x8B75,0xB5A1,0xD9C8,0xF2E7,0xFEFA,0xF9FD,0xE6F2,0xC7D8,0x9FB4,0x7389,0x485D,0x2435,0x0C16,0xFF04,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF
H:    .dw 0x0501,0x1A0E,0x3D2A,0x6852,0x9780,0xC3AE,0xE5D5,0xF9F1,0xFDFD,0xF0F9,0xD3E3,0xABC1,0x7D95,0x5066,0x283B,0x0D19,0xFF05,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF
;     === ===============================================================================================================================================================================================================================
C2:   .dw 0x0601,0x1D10,0x442F,0x735A,0xA48C,0xD0BB,0xEFE1,0xFDF8,0xF8FD,0xE1EF,0xBBD0,0x8CA4,0x5A73,0x2F44,0x101D,0xFF06,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF
CIS2: .dw 0x0701,0x2111,0x4B34,0x7E64,0xB198,0xDCC8,0xF7EC,0xFDFD,0xEEF8,0xCCDF,0x9DB6,0x6983,0x3950,0x1424,0xFF09,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF
D2:   .dw 0x0802,0x2513,0x533A,0x8A6E,0xBEA5,0xE7D5,0xFCF4,0xF9FD,0xDFEE,0xB2CA,0x7C98,0x4660,0x1C2F,0x040D,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF
DIS2: .dw 0x0902,0x2916,0x5B40,0x9679,0xCBB2,0xF1E1,0xFEFA,0xEFFA,0xC9DF,0x93B0,0x5976,0x273E,0x0814,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF,0xFFFF

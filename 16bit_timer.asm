.DEVICE atmega328p                      ; Anweisung für gavrasm

.def    temp = r16                      ; Register für das speichern temporärer Werte 
.def    leds = r17                      ; Register für das speichern des Zustands der Ausgänge
.def    prst = r18                      ; Register für das speichern des Zähler Presets

.org    0x0000
        rjmp    setup                   ; 'setup' als Start-Routine registrieren
        
.org    OVF1addr
        rjmp    t1over                  ; 't1over' als Timer1 Overflow-Routine registrieren

.equ    TPBH = 0xe0                     ; High Byte des Timer Presets
.equ    TPBL = 0xc0			; Low  Byte des Timer Presets

.equ	TPSC = 0x01			; Timer Prescaler (1 = 1, 2 = 8, 3 = 64, 4 = 256, 5 = 1024)

setup:
        ldi     temp,   HIGH(RAMEND)    ; Stackpointer initialisieren
        out     SPH,    temp            ; -- " --
        ldi     temp,   LOW (RAMEND)    ; -- " --
        out     SPL,    temp            ; -- " --
        
        ldi     temp,   $ff             ; PORTB als Ausgang setzen
        out     DDRB,   temp            ; -- " --
        
        ldi     leds,   $ff             ; Ausgangsstatus "vormerken"

        ldi     temp,   $00             ; Timer1 einstellen auf: kein Waveform-Generation & kein Compare-Match-Interrupt
        sts     TCCR1A, temp		; -- " --
        ldi     temp,   TPSC		; Timer1-Prescaler einstellen auf 1
        sts     TCCR1B, temp            ; -- " --

        ldi     temp,   $01             ; Timer1 als Overflow-Interrupt einstellen
        sts     TIMSK1, temp            ; -- " --
        
        ldi     prst,   TPBH            ; Timer1-Preset einstellen
        sts     TCNT1H, prst            ; -- " --
        ldi     prst,   TPBL            ; Timer1-Preset einstellen
        sts     TCNT1L, prst            ; -- " --
        
        sei                             ; Interrupts einschalten

loop:	rjmp    loop                    ; Eine leere Schleife, damit wir irgendwohin zurückkehren können

t1over:                                 ; Timer1 Overflow-Interrupt-Routine
        ldi     prst,   TPBH            ; Timer1-Preset einstellen
        sts     TCNT1H, prst            ; -- " --
        ldi     prst,   TPBL            ; Timer1-Preset einstellen
        sts     TCNT1L, prst            ; -- " --

	out     PORTB,  leds            ; Den gewünschten Status auf PORTB schreiben
	com     leds                    ; Einerkomplement vom Ausgangsstatus bilden für das nächste Mal

	reti                            ; Aus dem Interrupt zurückkehren

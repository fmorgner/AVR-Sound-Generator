; Programm zur Erzeugung eines 10kHZ Interrupts

.DEVICE atmega328p

.def    temp = r16                      ; Register für das speichern temporärer Werte 
.def    leds = r17                      ; Register für das speichern des Zustands der Ausgänge
.def    prst = r18                      ; Register für das speichern des Zähler Presets

.org    0x0000
        rjmp    setup                   ; 'setup' als Start-Routine registrieren
        
.org    OVF0addr
        rjmp    t0over                  ; 't0over' als Timer0 Overflow-Routine registrieren


setup:
        ldi     temp,   HIGH(RAMEND)    ; Stackpointer initialisieren
        out     SPH,    temp            ; -- " --
        ldi     temp,   LOW (RAMEND)    ; -- " --
        out     SPL,    temp            ; -- " --
        
        ldi     temp,   $ff             ; PORTB als Ausgang setzen
        out     DDRB,   temp            ; -- " --
        
        ldi     leds,   $ff             ; Ausgangsstatus "vormerken"

        ldi     temp,   $00             ; Timer0 einstellen auf: kein Waveform-Generation & kein Compare-Match-Interrupt
        out     TCCR0A, temp            ; -- " --
        ldi     temp,   $01             ; Timer0-Prescaler einstellen auf 1
        out     TCCR0B, temp            ; -- " --

        ldi     temp,   $02             ; Timer0 als Overflow-Interrupt einstellen
        sts     TIMSK0, temp            ; -- " --
        
        ldi     prst,   $e5             ; Timer0-Preset auf 96 einstellen
        out     TCNT0,  prst            ; -- " --
        
        sei                             ; Interrupts einschalten

loop:   rjmp    loop                    ; Eine leere Schleife, damit wir irgendwohin zurückkehren können

t0over:                                 ; Timer0 Overflow-Interrupt-Routine
	out     PORTB,  leds            ; Den gewünschten Status auf PORTB schreiben
	com     leds                    ; Einerkomplement vom Ausgangsstatus bilden für das nächste Mal

        out     TCNT0,  prst            ; Timer0-Preset wieder auf 96 einstellen

	reti                            ; Aus dem Interrupt zurückkehren

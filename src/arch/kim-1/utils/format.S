; ---------------------------------------------------------------------------
;
; K-1013 format utility
;
; Copyright © 2024 Eduardo Casino
; This file is licensed under the terms of the 2-clause BSD license. Please
; see the COPYING file in the root project directory for the full text.
;
; The low-level disk routines are basically copied from MTU's K-1013
; diagnostics.
;
; ---------------------------------------------------------------------------

#include "zif.inc"
#include "cpm65.inc"
#include "k-1013.inc"

NSTAG = 8                   ; Number of sectors to stagger per track

DMA_BUFFER = $fd00          ; We are using the 256-byte page just below the disk
DMA_AREA = $f4              ; buffer ($fd00), which encodes to $f4. See K-1013 manual.
FILLER = 0xe5               ; Data field filler byte

    .bss

; Uninitiaized program variables

drive:          .fill 1
drive_letter:   .fill 1
track:          .fill 1
side:           .fill 1
sector:         .fill 1
stagger:        .fill 1
disk_status:    .fill 8     ; Result phase readouts from NEC-765

    .text

zproc format
    ; Put the disk controller in a sane state

    lda HSRC                ; Test if an interrupt is pending
    zif pl
        jsr fdc_exec_senseint
    zendif

    ; Recalibrate (send heads to track 0)

    ldy drive
    jsr fdc_exec_recal
    zif cs
        jmp recal_error
    zendif

    lda #0                  ; Set DMA read mode, unprotect SYSRAM
    sta HSRC
    sta side                ; Initialize disk side,
    sta track               ; track number
    sta stagger             ; and stagger factor

    ; Create formatting data area for next track

    zloop
        jsr print_dot

        ldx stagger         ; Initialize sector number pointer
        ldy #0              ; Initialize pointer into format data area
        zrepeat
            lda track       ; Put track number,
            sta DMA_BUFFER,Y
            iny
            lda side        ; side number
            sta DMA_BUFFER,Y
            iny
            lda alttab,X    ; Lookup sector number in alternate table
            sta DMA_BUFFER,Y
            iny
            lda #1          ; 256 bytes per sector
            sta DMA_BUFFER,Y
            iny
            inx             ; Increment sector number pointer
            txa             ; Mod 26
            jsr mod26
            tax
            cpy #26*4       ; Test if 26 sectors gone through
        zuntil eq

        ldy drive
        jsr fdc_exec_format
        zif cs
            jmp format_error
        zendif

        ldy #0              ; Wait at least 500uS after write to allow the write
        zrepeat             ; current to decay before seeking again
            dey
        zuntil eq

        lda stagger         ; Add in stagger factor for next track
        clc
        adc #26-NSTAG
        jsr mod26           ; Sum mod 26
        sta stagger         ;

        inc track           ; Increment track number
        lda track
        cmp #77             ; Test if all tracks formatted
        zbreakif eq         ; If so, finished

        ldy drive           ; Seek to the new track
        jsr fdc_exec_seek
        zif cs
            jmp seek_error
        zendif
    zendloop

    clc
    rts
zendproc

; Calculate modulo 26 of A
;
zproc mod26
    zloop
        cmp     #26         ; Return a mod 26
        zbreakif cc
        sbc     #26         ; If not, substract 26
    zendloop
    rts
zendproc

zproc verify
    ; Recalibrate (send heads to track 0)

    ldy drive
    jsr fdc_exec_recal
    zif cs
        jmp recal_error
    zendif

    lda #1                  ; Set DMA write mode, unprotect SYSRAM
    sta HSRC

    lda #0
    sta side                ; Initialize disk side,
    sta track               ; track,

    zloop
        jsr print_dot

        lda #0              ; Init sector number
        sta sector

        zrepeat
            lda sector
            ldx track
            ldy drive

            jsr fdc_exec_read
            zif cs
                jmp verify_error
            zendif

            ldy #0
            zrepeat
                lda DMA_BUFFER,Y
                cmp #FILLER
                zif ne
                    jmp verify_error
                zendif
                iny
            zuntil eq

            inc sector
            lda sector
            cmp #26
        zuntil eq

        inc track           ; Increment track number
        lda track
        cmp #77             ; Test if all tracks verified
        zbreakif eq         ; If so, finished

        ldy drive           ; Seek to the new track
        jsr fdc_exec_seek
        zif cs
            jmp seek_error
        zendif
    zendloop

    clc
    rts

zendproc

zproc main
    ; Get drive from command line

    lda cpm_fcb+1
    cmp #' '                ; File name must be empty
    bne usage
	lda cpm_fcb
    cmp #0                  ; Drive number can't be default
    beq usage

    ; Get drive number in base 0 and drive leter

    sec
    sbc #1
    sta drive
    clc
    adc #'A'
    sta drive_letter

    ; Check if the drive exists

    lda drive
    ldy #BIOS_SELDSK
    jsr BIOS
    bcs invalid

    ; Warning message

    lda drive_letter
    sta warning_drv
    lda #<warning_msg
    ldx #>warning_msg
    ldy #BDOS_WRITE_STRING
    jsr BDOS

    ; Get confirmation

    ldy #BDOS_CONSOLE_INPUT
    jsr BDOS
    cmp #'y'
    bne abort

    lda #<crlf
    ldx #>crlf
    ldy #BDOS_WRITE_STRING
    jsr BDOS

    jsr format

    zif cc
        lda #<verify_msg
        ldx #>verify_msg
        ldy #BDOS_WRITE_STRING
        jsr BDOS

        jsr verify

        zif cc
            lda #<done_msg
            ldx #>done_msg
            ldy #BDOS_WRITE_STRING
            jmp BDOS
        zendif
    zendif

    rts

zendproc

; Error routines
;
zproc usage
    lda #<usage_msg
    ldx #>usage_msg
    ldy #BDOS_WRITE_STRING
    jmp BDOS
zendproc

zproc recal_error
    lda #<recal_msg
    ldx #>recal_msg
    jmp print_err
zendproc

zproc seek_error
    lda #<seek_msg
    ldx #>seek_msg
    ldy #BDOS_WRITE_STRING
    jsr BDOS
    lda track
    jsr print_byte
    lda #<seek_msg2
    ldx #>seek_msg2
    jmp print_err
zendproc

zproc invalid
    lda drive_letter
    sta invalid_drv
    lda #<invalid_msg
    ldx #>invalid_msg
    ldy #BDOS_WRITE_STRING
    jmp BDOS
zendproc

zproc abort
    lda #<abort_msg
    ldx #>abort_msg
    ldy #BDOS_WRITE_STRING
    jmp BDOS
zendproc

zproc print_dot
    lda #'.'
    ldy #BIOS_CONOUT
    jmp BIOS
zendproc

zproc verify_error
    lda #<vererr_msg
    ldx #>vererr_msg
    ldy #BDOS_WRITE_STRING
    jsr BDOS
    lda sector
    jsr print_byte
    lda #<vererr_msg2
    ldx #>vererr_msg2
    ldy #BDOS_WRITE_STRING
    jsr BDOS
    lda track
    jsr print_byte
    lda #<vererr_msg3
    ldx #>vererr_msg3
    jmp print_err
zendproc

zproc format_error
    lda #<format_msg
    ldx #>format_msg
    ldy #BDOS_WRITE_STRING
    jsr BDOS
    lda track
    jsr print_byte
    lda #<format_msg2
    ldx #>format_msg2
zendproc
; Fall through
zproc print_err
    ldy #BDOS_WRITE_STRING
    jsr BDOS
    sec
    rts
zendproc

; This routine assumes A < 100 (disk has 77 tracks)
;
; Derived from https://beebwiki.mdfs.net/Number_output_in_6502_machine_code
;
zproc print_byte
    ldx #$ff
    sec
    zrepeat
        inx                 ; Count number of 10s
        sbc #10
    zuntil cc
    adc #10
    pha                     ; Save units
    txa
    zif ne
        jsr print_digit
    zendif
    pla                     ; Restore units
zendproc
; Fall through
zproc print_digit
    ora #'0'
    ldy #BIOS_CONOUT
    jmp BIOS
zendproc

;
; Disk access routines
;

zproc fdc_exec_specify
    ; Save cylinder for later check

    ldx #fdc_specify-fdc_commands ; Command index into X
    jsr fdc_exec_command
    rts
zendproc

; Drive in Y

zproc fdc_exec_recal
    ; Save cylinder for later check

    lda #0
    pha

    ; Put drive in second byte of command

    sty fdc_recal+2

    ldx #fdc_recal-fdc_commands ; Command index into X
    jsr fdc_exec_command
    bcs fdc_pla_ret

    jsr fdc_exec_senseint
    bcs fdc_pla_ret

    ; Compare cylinder number with desired one in ST1

    pla
    cmp disk_status+1
    zif ne
        sec
        rts
    zendif
    clc
    rts
zendproc

zproc fdc_pla_ret
    pla
    rts
zendproc

; Seek track in A, drive in Y

zproc fdc_exec_seek

    ; Save cylinder for later check

    pha

    ; Put new cylinder number into third byte of seek command

    sta fdc_seek+3
    sty fdc_seek+2              ; Put drive in second byte of command

    ldx #fdc_seek-fdc_commands  ; Command index into X
    jsr fdc_exec_command
    bcs fdc_pla_ret

    jsr fdc_exec_senseint
    bcs fdc_pla_ret

    ; Compare cylinder number with desired one in ST1

    pla
    cmp disk_status+1
    bne fdc_fail

    clc
    rts
zendproc

zproc fdc_exec_senseint
    ; Wait until FDC interrupt

    zrepeat
        lda HSRC
    zuntil pl

    ; Execute Sense Interrupt command

    ldx #fdc_senseint-fdc_commands
    jsr fdc_exec_command
    zif cc
        ; Read results into memory

        jsr fdc_read_result
        zif cc
            ; Look for error in the status registers

            lda disk_status     ; Check ST0
            and #0xf8           ; Delete don't care bits
            cmp #0x20           ; Result must be "Seek Completed"
            bne fdc_fail
            clc
        zendif
    zendif
    rts
zendproc

; Format track
; Drive in Y, track data in area pointed by ADMA

zproc fdc_exec_format

    sty fdc_format+2              ; Put drive in second byte of command

    lda #DMA_AREA
    sta ADMA

    ldx #fdc_format-fdc_commands  ; Command index into X
    jsr fdc_exec_command
    zif cs
        rts
    zendif

    ; Wait until IRQ from FDC

    zrepeat
        lda HSRC            ; Wait until IRQ from FDC
    zuntil pl

    ; Read results into memory

    jsr fdc_read_result
    zif cs
        rts
    zendif

    ; Look for error in the status registers

    lda disk_status     ; Check ST0
    and #0xd8           ; Delete don't care bits
    bne fdc_fail        ; Error if any remainder set
    lda disk_status+1   ; Check ST1
    and #0x35           ; Delete don't care bits
    bne fdc_fail        ; Error if any remainder set
    lda disk_status+2   ; Check ST2
    and #0x33           ; Mask out non-error bits
    bne fdc_fail        ; Error if any remainder set

    clc
    rts
zendproc

zproc fdc_read_result
    ldx #0
    zloop
        zrepeat
            lda MSTR        ; Wait until RQM from controller
        zuntil mi
        and #0x40           ; Test data direction bit
        beq fdc_fail        ; Error if controller wants to listen

        lda DATR            ; Get status byte from data register
        sta disk_status, x  ; Put it into memory
        inx                 ; Next byte
        nop                 ; Give the controller time to update
        nop                 ; the MSTR with a valid busy status
        lda MSTR            ; Check if still busy and get next
        and #0x10           ; byte while so
    zuntil eq

    clc
    rts
zendproc

zproc fdc_fail
    sec
    rts
zendproc

; Sector num in A, cylinder in X, drive in Y

zproc fdc_exec_read

    stx fdc_read+3      ; Put cylinder in third byte of command
    sta fdc_read+5      ; Put sector in fifth byte of command
    sta fdc_read+7      ; Put last sector in seventh byte of command
    sty fdc_read+2      ; Put drive in second byte of command

    lda #DMA_AREA
    sta ADMA

    ; Read/Write data into/from disk buffer

    ldx #fdc_read-fdc_commands ; Command index into X
    jsr fdc_exec_command
    zif cs
        rts
    zendif

    ; Wait until IRQ from FDC

    zrepeat
        lda HSRC        ; Wait until IRQ from FDC
    zuntil pl

    ; Read results into memory

    jsr fdc_read_result
    zif cs
        rts
    zendif

    ; Look for error in the status registers

    lda disk_status     ; Check ST0
    and #0xd8           ; Delete don't care bits
    zif ne
        ; ST0 is not clear, dig further
        cmp #0x40           ; Test if abnormal termination
        bne fdc_fail        ; Real error if not
        lda disk_status+1   ; If abnormal termination, check ST1 for end of cylinder
        bpl fdc_fail        ; Nope, then it is an error
    zendif
    lda disk_status+1   ; Check ST1
    and #0x37           ; Mask out non-error bits
    bne fdc_fail        ; Error if any remainder set
    lda disk_status+2   ; Check ST2
    and #0x33           ; Mask out non-error bits
    bne fdc_fail        ; Error if any remainder set

    clc
    rts
zendproc

; Command index in X

zproc fdc_exec_command
    zloop
        lda #0x10           ; Check if uPD765 is busy processing a command
        and MSTR            ;   (should not occur, but happens)
        zbreakif eq         ; Not busy, go execute command
                            ; Yes, execute recovery procedure
        zrepeat
            bit MSTR        ; wait until ready to read or write
        zuntil mi

        zif vc              ; Data register ready to write
            lda #$00        ; Try to complete command sequence
            sta DATR
            beq 1f          ; And try again
        zendif
                            ; Else, data register needs to be read
        lda DATR            ; Read status register
1:      nop                 ; Wait a few cycles
        nop
    zendloop

    ldy fdc_commands, x     ; Load command length
    inx

    zloop
        zrepeat
            lda MSTR        ; Wait until RQM from controller
        zuntil mi
        and #0x40           ; Test data direction bit
        bne fdc_fail        ; Error if controller wants to talk

        lda fdc_commands, x ; Get command byte
        sta DATR            ; Store into FDC data register
        inx                 ; Next command byte
        dey
    zuntil eq

    clc
    rts
zendproc

    .rodata

; Constants

alttab: .byte   0,  13, 1,  14  ; Table of interleaved sector numbers
        .byte   2,  15, 3,  16  ; Interleave factor = 2
        .byte   4,  17, 5,  18
        .byte   6,  19, 7,  20
        .byte   8,  21, 9,  22
        .byte   10, 23, 11, 24
        .byte   12, 25

    .data

; NEC-765 pre-formatted command strings

fdc_commands:
fdc_specify:
    .byte 3             ; Command length
    .byte 3             ; Specify  
    .byte 0x6f          ; Step Rate Time   = 10ms, Head Unload Time = 240ms
    .byte 0x20          ; Head Load Time   = 32ms
                                            
fdc_recal:
    .byte 2             ; Command length
    .byte 7             ; Recalibrate
    .byte 0             ; Drive

fdc_senseint:
    .byte 1             ; Command length
    .byte 8             ; Sense Interrupt Status

fdc_seek:
    .byte 3             ; Command length
    .byte 0xf           ; Command code
    .byte 0             ; Drive number in bits 0-1, side number in bit 2
    .byte 0             ; NCN: New cylinder number

fdc_format:
    .byte 6             ; Command length
    .byte 0x4d          ; Format a double density track command
    .byte 0             ; Drive number in bits 0-1, side number in bit 2
    .byte 1             ; Specify 256 bytes/sector
    .byte 0x1a          ; Specify 26 sectors/track
    .byte 0x36          ; Gap length for 26 sectors, 256 bytes/sect
    .byte FILLER        ; Data field filler byte

fdc_read:
    .byte 9             ; Command length
    .byte 0x46          ; Read command code.
    .byte 0             ; Drive number in bits 0-1, side number in bit 2
    .byte 0             ; C: Present cylinder number. Must match current track
    .byte 0             ; H: Head
    .byte 0             ; R: Sector number to read
    .byte 1             ; N: Code for 256 bytes per sector
    .byte 0             ; EOT: Last sector to read
    .byte 0xe           ; GPL: Gap length for 26 sectors, 256 bytes/sect
    .byte 0xff          ; DTL: Data length = 0xff since N is non-zero

; Messages

invalid_msg:    .ascii "Error: invalid drive '"
invalid_drv:    .byte 0
                .ascii "'."
crlf:           .byte 13,10,0

usage_msg:      .ascii "Syntax: format <drive>"
                .byte 13,10,0

warning_msg:    .ascii "Warning: about to format drive '"
warning_drv:    .byte 0
                .ascii "',\n\rdestroying everything on it."
                .byte 13,10
                .ascii "Press Y to proceed, anything else to cancel: "
                .byte 0

abort_msg:      .byte 13,10
                .ascii "Aborted by user."
                .byte 13,10,0

verify_msg:     .byte 13,10
                .ascii "Verifying:"
                .byte 13,10,0

done_msg:       .byte 13,10
                .ascii "Done."
                .byte 13,10,0

format_msg:     .byte 13,10
                .ascii "Error: Unable to format track "
                .byte 0
format_msg2:    .byte '.',13,10,0

vererr_msg:     .byte 13,10
                .ascii "Error reading sector "
                .byte 0
vererr_msg2:    .ascii ", track "
                .byte 0
vererr_msg3:    .byte '.',13,10,0

recal_msg:      .ascii "Error: Unable to retract head to track 0."
                .byte 13,10,0

seek_msg:       .byte 13,10
                .ascii "Error: Unable to position head over cylinder "
                .byte 0
seek_msg2:      .byte '.',13,10,0
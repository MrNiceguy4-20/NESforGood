//
//  TriangleChannel.swift
//  nesforgood
//
//  Created by kevin on 2025-10-30.
//


class TriangleChannel {
    weak var apu: APU?
    
    var enabled: Bool = false
    var lengthHalt: Bool = false
    var linearLoad: UInt8 = 0
    var linearReload: Bool = false
    var linearCounter: UInt8 = 0
    
    var period: UInt16 = 0
    var timer: UInt16 = 0
    var lengthCounter: UInt8 = 0
    var sequencer: UInt8 = 0
    
    static let waveTable: [UInt8] = [
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
        15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0
    ]
    
    static let lengthTable = PulseChannel.lengthTable
    
    func write(reg: UInt8, value: UInt8) {
        switch reg {
        case 0:
            lengthHalt = (value & 0x80) != 0
            linearLoad = value & 0x7F
        case 2:
            period = (period & 0xFF00) | UInt16(value)
        case 3:
            period = (period & 0x00FF) | (UInt16(value & 0x07) << 8)
            if enabled { lengthCounter = TriangleChannel.lengthTable[Int(value >> 3)] }
            linearReload = true
        default: break
        }
    }
    
    func clockTimer() {
        if timer == 0 {
            timer = period
            if linearCounter > 0 && lengthCounter > 0 {
                sequencer = (sequencer &+ 1) & 31
            }
        } else {
            timer &-= 1
        }
    }
    
    func clockLinear() {
        if linearReload { linearCounter = linearLoad }
        else if linearCounter > 0 { linearCounter &-= 1 }
        if !lengthHalt { linearReload = false }
    }
    
    func clockLength() {
        if !lengthHalt && lengthCounter > 0 { lengthCounter &-= 1 }
    }
    
    var output: UInt8 {
        if !enabled || linearCounter == 0 || lengthCounter == 0 || period < 2 { return 0 }
        return TriangleChannel.waveTable[Int(sequencer)]
    }
}
import Foundation

func zipArchive(entries: [(String, Data, UInt32)]) -> Data {
  var local = Data()
  var central = Data()
  func number<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    var little = value.littleEndian
    withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
  }
  for (path, content, mode) in entries {
    let name = Data(path.utf8)
    let offset = UInt32(local.count)
    var crc: UInt32 = 0xffff_ffff
    for byte in content {
      crc ^= UInt32(byte)
      for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 0 ? 0 : 0xedb8_8320) }
    }
    crc ^= 0xffff_ffff
    number(UInt32(0x0403_4b50), to: &local)
    for value: UInt16 in [20, 0, 0, 0, 0] { number(value, to: &local) }
    for value in [crc, UInt32(content.count), UInt32(content.count)] { number(value, to: &local) }
    number(UInt16(name.count), to: &local)
    number(UInt16(0), to: &local)
    local.append(name)
    local.append(content)
    number(UInt32(0x0201_4b50), to: &central)
    for value: UInt16 in [0x0314, 20, 0, 0, 0, 0] { number(value, to: &central) }
    for value in [crc, UInt32(content.count), UInt32(content.count)] {
      number(value, to: &central)
    }
    for value: UInt16 in [UInt16(name.count), 0, 0, 0, 0] { number(value, to: &central) }
    number(mode << 16, to: &central)
    number(offset, to: &central)
    central.append(name)
  }
  let offset = UInt32(local.count)
  local.append(central)
  number(UInt32(0x0605_4b50), to: &local)
  for value: UInt16 in [0, 0, UInt16(entries.count), UInt16(entries.count)] {
    number(value, to: &local)
  }
  number(UInt32(central.count), to: &local)
  number(offset, to: &local)
  number(UInt16(0), to: &local)
  return local
}

import 'dart:typed_data';

class RingSamplePacket {
  final int seq;
  final int tsMs;
  final int ir;
  final int red;

  RingSamplePacket({
    required this.seq,
    required this.tsMs,
    required this.ir,
    required this.red,
  });

  static RingSamplePacket fromBytes(Uint8List b) {
    if (b.length < 16) {
      throw FormatException('Packet too short: ${b.length}');
    }
    final bd = ByteData.sublistView(b);
    return RingSamplePacket(
      seq: bd.getUint32(0, Endian.little),
      tsMs: bd.getUint32(4, Endian.little),
      ir: bd.getInt32(8, Endian.little),
      red: bd.getInt32(12, Endian.little),
    );
  }
}
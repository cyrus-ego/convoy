// Model khớp với docs/protocol.md

enum Role {
  leader,
  sweeper,
  member;

  static Role parse(String s) => Role.values.firstWhere((r) => r.name == s, orElse: () => Role.member);

  String get label => switch (this) {
        Role.leader => 'Trưởng đoàn',
        Role.sweeper => 'Chốt đoàn',
        Role.member => 'Thành viên',
      };
}

class Pos {
  const Pos({required this.ts, required this.lat, required this.lng, required this.acc, this.spd, this.hdg, this.bat});

  final int ts;
  final double lat;
  final double lng;
  final double acc;
  final double? spd;
  final double? hdg;
  final int? bat;

  factory Pos.fromJson(Map<String, dynamic> j) => Pos(
        ts: (j['ts'] as num).toInt(),
        lat: (j['lat'] as num).toDouble(),
        lng: (j['lng'] as num).toDouble(),
        acc: (j['acc'] as num).toDouble(),
        spd: (j['spd'] as num?)?.toDouble(),
        hdg: (j['hdg'] as num?)?.toDouble(),
        bat: (j['bat'] as num?)?.toInt(),
      );

  Map<String, dynamic> toMsg() => {
        't': 'pos',
        'ts': ts,
        'lat': lat,
        'lng': lng,
        'acc': acc,
        if (spd != null) 'spd': spd,
        if (hdg != null) 'hdg': hdg,
        if (bat != null) 'bat': bat,
      };
}

class MemberState {
  const MemberState({
    required this.uid,
    required this.name,
    required this.role,
    required this.color,
    required this.online,
    required this.sharing,
    required this.sos,
    required this.pos,
  });

  final String uid;
  final String name;
  final Role role;

  /// Dạng '#RRGGBB'
  final String color;
  final bool online;
  final bool sharing;
  final bool sos;
  final Pos? pos;

  factory MemberState.fromJson(Map<String, dynamic> j) => MemberState(
        uid: j['uid'] as String,
        name: j['name'] as String,
        role: Role.parse(j['role'] as String),
        color: j['color'] as String,
        online: j['online'] as bool,
        sharing: j['sharing'] as bool,
        sos: j['sos'] as bool,
        pos: j['pos'] == null ? null : Pos.fromJson(j['pos'] as Map<String, dynamic>),
      );
}

class TripInfo {
  const TripInfo({
    required this.id,
    required this.name,
    required this.status,
    required this.inviteCode,
    required this.lagThresholdM,
  });

  final String id;
  final String name;
  final String status;
  final String inviteCode;
  final int lagThresholdM;

  bool get ended => status == 'ended';

  factory TripInfo.fromJson(Map<String, dynamic> j) => TripInfo(
        id: j['id'] as String,
        name: j['name'] as String,
        status: j['status'] as String,
        inviteCode: j['inviteCode'] as String,
        lagThresholdM: (j['lagThresholdM'] as num).toInt(),
      );
}

class Regroup {
  const Regroup({required this.lat, required this.lng, required this.title, required this.setBy, required this.setAt});

  final double lat;
  final double lng;
  final String title;
  final String setBy;
  final int setAt;

  factory Regroup.fromJson(Map<String, dynamic> j) => Regroup(
        lat: (j['lat'] as num).toDouble(),
        lng: (j['lng'] as num).toDouble(),
        title: j['title'] as String,
        setBy: j['setBy'] as String,
        setAt: (j['setAt'] as num).toInt(),
      );
}

class TripEvent {
  const TripEvent({required this.id, required this.type, required this.uid, required this.at, this.data = const {}});

  final int id;
  final String type;
  final String? uid;
  final int at;
  final Map<String, dynamic> data;

  factory TripEvent.fromJson(Map<String, dynamic> j) => TripEvent(
        id: (j['id'] as num).toInt(),
        type: j['type'] as String,
        uid: j['uid'] as String?,
        at: (j['at'] as num).toInt(),
        data: (j['data'] as Map<String, dynamic>?) ?? const {},
      );
}

sealed class ServerMsg {
  const ServerMsg();

  /// Trả về null nếu bản tin không hiểu được (server mới hơn app chẳng hạn).
  static ServerMsg? tryParse(Map<String, dynamic> j) {
    try {
      return switch (j['t']) {
        'snapshot' => SnapshotMsg(
            serverTime: (j['serverTime'] as num).toInt(),
            trip: TripInfo.fromJson(j['trip'] as Map<String, dynamic>),
            members: _members(j['members']),
            regroup: j['regroup'] == null ? null : Regroup.fromJson(j['regroup'] as Map<String, dynamic>),
          ),
        'delta' => DeltaMsg(serverTime: (j['serverTime'] as num).toInt(), members: _members(j['members'])),
        'regroup' => RegroupMsg(j['regroup'] == null ? null : Regroup.fromJson(j['regroup'] as Map<String, dynamic>)),
        'event' => EventMsg(TripEvent.fromJson(j['event'] as Map<String, dynamic>)),
        _ => null,
      };
    } on Object {
      return null;
    }
  }

  static List<MemberState> _members(Object? list) =>
      (list as List).map((e) => MemberState.fromJson(e as Map<String, dynamic>)).toList();
}

class SnapshotMsg extends ServerMsg {
  const SnapshotMsg({required this.serverTime, required this.trip, required this.members, required this.regroup});
  final int serverTime;
  final TripInfo trip;
  final List<MemberState> members;
  final Regroup? regroup;
}

class DeltaMsg extends ServerMsg {
  const DeltaMsg({required this.serverTime, required this.members});
  final int serverTime;
  final List<MemberState> members;
}

class RegroupMsg extends ServerMsg {
  const RegroupMsg(this.regroup);
  final Regroup? regroup;
}

class EventMsg extends ServerMsg {
  const EventMsg(this.event);
  final TripEvent event;
}

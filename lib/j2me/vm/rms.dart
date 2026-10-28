import 'dart:convert';
import 'dart:typed_data';

import 'vm.dart';

/// Un « record store » : la sauvegarde d'un jeu (scores, niveaux, options).
class RmsStore {
  RmsStore(this.name);

  final String name;
  int nextId = 1;
  int version = 0;
  final Map<int, Uint8List> records = {};

  int get bytes {
    var total = 0;
    for (final r in records.values) {
      total += r.length;
    }
    return total;
  }
}

/// Toutes les sauvegardes d'un jeu. Vit en mémoire ; pour les garder entre deux
/// parties, enregistre [toJson] dans un fichier quand [onChanged] est appelé,
/// puis relis-le avec [loadJson] avant de lancer le jeu.
class RmsBackend {
  final Map<String, RmsStore> stores = {};

  /// Appelé après chaque modification (ajout, changement, suppression).
  void Function()? onChanged;

  Map<String, Object?> toJson() => {
        for (final s in stores.values)
          s.name: {
            'next': s.nextId,
            'version': s.version,
            'records': {
              for (final e in s.records.entries) '${e.key}': base64Encode(e.value),
            },
          },
      };

  void loadJson(Map<String, Object?> json) {
    stores.clear();
    json.forEach((name, value) {
      final m = value as Map<String, Object?>;
      final s = RmsStore(name);
      s.nextId = m['next'] as int;
      s.version = m['version'] as int;
      (m['records'] as Map<String, Object?>).forEach((id, b) {
        s.records[int.parse(id)] = base64Decode(b as String);
      });
      stores[name] = s;
    });
  }
}

class _Open {
  _Open(this.store);

  final RmsStore store;
  bool open = true;
}

class _REnum {
  _REnum(this.store, this.ids);

  final RmsStore store;
  final List<int> ids;
  int i = 0;
}

Uint8List _slice(Object? arr, int off, int len) {
  if (arr == null) {
    if (len == 0) return Uint8List(0);
    throw JavaThrow('java/lang/NullPointerException');
  }
  final d = (arr as JArray).data as Int8List;
  if (off < 0 || len < 0 || off + len > d.length) {
    throw JavaThrow('java/lang/ArrayIndexOutOfBoundsException');
  }
  final u = d.buffer.asUint8List(d.offsetInBytes, d.length);
  return Uint8List.fromList(Uint8List.sublistView(u, off, off + len));
}

/// À appeler après registerNatives(). Les sauvegardes vont dans [backend].
void registerRms(Vm vm, RmsBackend backend) {
  final n = vm.natives;
  const p = 'javax/microedition/rms/';

  vm.defineClass('${p}RecordStoreException', 'java/lang/Exception');
  for (final e in const [
    'RecordStoreNotFoundException',
    'RecordStoreNotOpenException',
    'RecordStoreFullException',
    'InvalidRecordIDException',
  ]) {
    vm.defineClass('$p$e', '${p}RecordStoreException');
  }
  vm.defineClass('${p}RecordFilter', 'java/lang/Object', iface: true);
  vm.defineClass('${p}RecordComparator', 'java/lang/Object', iface: true);
  vm.defineClass('${p}RecordEnumeration', 'java/lang/Object', iface: true);
  vm.defineClass('${p}RecordStore', 'java/lang/Object');
  vm.defineClass(
    '${p}NativeRecordEnumeration',
    'java/lang/Object',
    interfaces: ['${p}RecordEnumeration'],
  );
  final storeCls = vm.classes['${p}RecordStore']!;
  final enumCls = vm.classes['${p}NativeRecordEnumeration']!;

  _Open op(List<Object?> a) {
    final s = (a[0] as JObject).native as _Open;
    if (!s.open) throw JavaThrow('${p}RecordStoreNotOpenException');
    return s;
  }

  Uint8List rec(_Open s, int id) {
    final r = s.store.records[id];
    if (r == null) throw JavaThrow('${p}InvalidRecordIDException', '$id');
    return r;
  }

  void changed(RmsStore s) {
    s.version++;
    backend.onChanged?.call();
  }

  JArray bytesOf(Uint8List b) => JArray('[B', Int8List.fromList(b));

  const rs = '${p}RecordStore';

  n['$rs.openRecordStore(Ljava/lang/String;Z)L$rs;'] = (vm, t, a) {
    final raw = a[0];
    if (raw == null) throw JavaThrow('java/lang/NullPointerException');
    final name = raw as String;
    var st = backend.stores[name];
    if (st == null) {
      if ((a[1] as int) == 0) {
        throw JavaThrow('${p}RecordStoreNotFoundException', name);
      }
      st = backend.stores[name] = RmsStore(name);
      backend.onChanged?.call();
    }
    return JObject(storeCls)..native = _Open(st);
  };
  n['$rs.deleteRecordStore(Ljava/lang/String;)V'] = (vm, t, a) {
    final name = a[0] as String?;
    if (name == null || backend.stores.remove(name) == null) {
      throw JavaThrow('${p}RecordStoreNotFoundException', name);
    }
    backend.onChanged?.call();
    return null;
  };
  n['$rs.listRecordStores()[Ljava/lang/String;'] = (vm, t, a) {
    if (backend.stores.isEmpty) return null;
    return JArray(
      '[Ljava/lang/String;',
      <Object?>[for (final k in backend.stores.keys) vm.intern(k)],
    );
  };

  n['$rs.closeRecordStore()V'] = (vm, t, a) {
    ((a[0] as JObject).native as _Open).open = false;
    return null;
  };
  n['$rs.getName()Ljava/lang/String;'] =
      (vm, t, a) => vm.intern(op(a).store.name);
  n['$rs.getVersion()I'] = (vm, t, a) => op(a).store.version;
  n['$rs.getLastModified()J'] = (vm, t, a) => 0;
  n['$rs.getNumRecords()I'] = (vm, t, a) => op(a).store.records.length;
  n['$rs.getNextRecordID()I'] = (vm, t, a) => op(a).store.nextId;
  n['$rs.getSize()I'] = (vm, t, a) => op(a).store.bytes;
  n['$rs.getSizeAvailable()I'] = (vm, t, a) {
    final free = 1024 * 1024 - op(a).store.bytes;
    return free < 0 ? 0 : free;
  };

  n['$rs.addRecord([BII)I'] = (vm, t, a) {
    final s = op(a).store;
    final data = _slice(a[1], a[2] as int, a[3] as int);
    final id = s.nextId++;
    s.records[id] = data;
    changed(s);
    return id;
  };
  n['$rs.getRecord(I)[B'] = (vm, t, a) => bytesOf(rec(op(a), a[1] as int));
  n['$rs.getRecord(I[BI)I'] = (vm, t, a) {
    final r = rec(op(a), a[1] as int);
    final out = (a[2] as JArray).data as Int8List;
    final off = a[3] as int;
    if (off < 0 || off + r.length > out.length) {
      throw JavaThrow('java/lang/ArrayIndexOutOfBoundsException');
    }
    for (var i = 0; i < r.length; i++) {
      out[off + i] = r[i];
    }
    return r.length;
  };
  n['$rs.getRecordSize(I)I'] = (vm, t, a) => rec(op(a), a[1] as int).length;
  n['$rs.setRecord(I[BII)V'] = (vm, t, a) {
    final o = op(a);
    final id = a[1] as int;
    rec(o, id);
    o.store.records[id] = _slice(a[2], a[3] as int, a[4] as int);
    changed(o.store);
    return null;
  };
  n['$rs.deleteRecord(I)V'] = (vm, t, a) {
    final o = op(a);
    final id = a[1] as int;
    rec(o, id);
    o.store.records.remove(id);
    changed(o.store);
    return null;
  };

  // ------------------------------------------------------- énumération
  var warned = false;
  n['$rs.enumerateRecords(L${p}RecordFilter;L${p}RecordComparator;Z)L${p}RecordEnumeration;'] =
      (vm, t, a) {
    final s = op(a).store;
    if ((a[1] != null || a[2] != null) && !warned) {
      warned = true;
      vm.log('RMS : filtres et comparateurs ignorés (ordre par identifiant).');
    }
    final ids = s.records.keys.toList()..sort();
    return JObject(enumCls)..native = _REnum(s, ids);
  };

  const en = '${p}NativeRecordEnumeration';
  _REnum re(List<Object?> a) => (a[0] as JObject).native as _REnum;
  int nextId(_REnum e) {
    if (e.i >= e.ids.length) throw JavaThrow('${p}InvalidRecordIDException');
    return e.ids[e.i++];
  }

  int prevId(_REnum e) {
    if (e.i <= 0) throw JavaThrow('${p}InvalidRecordIDException');
    return e.ids[--e.i];
  }

  Uint8List data(_REnum e, int id) {
    final r = e.store.records[id];
    if (r == null) throw JavaThrow('${p}InvalidRecordIDException', '$id');
    return r;
  }

  n['$en.hasNextElement()Z'] = (vm, t, a) {
    final e = re(a);
    return e.i < e.ids.length ? 1 : 0;
  };
  n['$en.hasPreviousElement()Z'] = (vm, t, a) => re(a).i > 0 ? 1 : 0;
  n['$en.nextRecordId()I'] = (vm, t, a) => nextId(re(a));
  n['$en.previousRecordId()I'] = (vm, t, a) => prevId(re(a));
  n['$en.nextRecord()[B'] = (vm, t, a) {
    final e = re(a);
    return bytesOf(data(e, nextId(e)));
  };
  n['$en.previousRecord()[B'] = (vm, t, a) {
    final e = re(a);
    return bytesOf(data(e, prevId(e)));
  };
  n['$en.numRecords()I'] = (vm, t, a) => re(a).ids.length;
  n['$en.reset()V'] = (vm, t, a) {
    re(a).i = 0;
    return null;
  };
  n['$en.rebuild()V'] = (vm, t, a) {
    final e = re(a);
    e.ids
      ..clear()
      ..addAll(e.store.records.keys.toList()..sort());
    e.i = 0;
    return null;
  };
  n['$en.keepUpdated(Z)V'] = (vm, t, a) => null;
  n['$en.isKeptUpdated()Z'] = (vm, t, a) => 0;
  n['$en.destroy()V'] = (vm, t, a) => null;
}

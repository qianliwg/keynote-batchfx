"""Minimal lossless protobuf / Apple Snappy IWA codec; no third-party dependencies."""
import copy
import struct

def varint(data, pos=0):
    value = 0
    for shift in range(0, 70, 7):
        b = data[pos]; pos += 1
        value |= (b & 127) << shift
        if b < 128:
            return value, pos
    raise ValueError('无效的整数编码')


def vint(n):
    out = bytearray()
    while n > 127:
        out.append((n & 127) | 128); n >>= 7
    out.append(n)
    return bytes(out)


class Message:
    def __init__(self, data=b''):
        self.fields = []
        pos = 0
        while pos < len(data):
            key, pos = varint(data, pos)
            number, wire = key >> 3, key & 7
            if not number:
                raise ValueError('无效字段')
            if wire == 0:
                val, pos = varint(data, pos)
            elif wire in (1, 5):
                size = 8 if wire == 1 else 4
                val = data[pos:pos+size]; pos += size
            elif wire == 2:
                size, pos = varint(data, pos)
                val = data[pos:pos+size]; pos += size
            else:
                raise ValueError('不支持的字段编码')
            if pos > len(data):
                raise ValueError('文件数据不完整')
            self.fields.append([number, wire, val])

    def pack(self):
        out = bytearray()
        for n, w, v in self.fields:
            out += vint(n << 3 | w)
            out += vint(v) if w == 0 else (vint(len(v)) + v if w == 2 else v)
        return bytes(out)

    def get(self, n, default=None):
        return next((v for k, w, v in self.fields if k == n), default)

    def all(self, n):
        return [v for k, w, v in self.fields if k == n]

    def set(self, n, w, v):
        indices = [i for i, f in enumerate(self.fields) if f[0] == n]
        if indices:
            self.fields[indices[0]] = [n, w, v]
            for i in reversed(indices[1:]): del self.fields[i]
        else:
            self.fields.append([n, w, v])

    def sub(self, *path):
        obj = self
        for n in path:
            data = obj.get(n)
            if data is None: raise ValueError('文稿对象结构已改变，请重新检查文稿')
            obj = Message(data)
        return obj

    def put(self, path, value):
        if len(path) == 1:
            self.set(path[0], 2, value.pack())
        else:
            sub = self.sub(path[0]); sub.put(path[1:], value)
            self.set(path[0], 2, sub.pack())

    def f(self, n, default=0.0):
        value = self.get(n)
        return struct.unpack('<f', value)[0] if value is not None else default

    def sf(self, n, value): self.set(n, 5, struct.pack('<f', value))
    def sd(self, n, value): self.set(n, 1, struct.pack('<d', value))


def unsnappy(data):
    expected, pos = varint(data)
    out = bytearray()
    while pos < len(data):
        tag = data[pos]; pos += 1
        mode = tag & 3
        if mode == 0:
            size = tag >> 2
            if size < 60:
                size += 1
            else:
                count = size - 59
                size = int.from_bytes(data[pos:pos+count], 'little') + 1
                pos += count
            out += data[pos:pos+size]; pos += size
        else:
            if mode == 1:
                size = 4 + ((tag >> 2) & 7)
                offset = ((tag & 224) << 3) | data[pos]; pos += 1
            else:
                size = 1 + (tag >> 2)
                count = 2 if mode == 2 else 4
                offset = int.from_bytes(data[pos:pos+count], 'little'); pos += count
            if offset <= 0 or offset > len(out): raise ValueError('无效的压缩数据')
            for _ in range(size): out.append(out[-offset])
    if len(out) != expected: raise ValueError('解压长度不一致')
    return bytes(out)


def unpack_iwa(data):
    raw = bytearray(); pos = 0
    while pos < len(data):
        if data[pos] != 0: raise ValueError('不支持的 IWA 数据块')
        size = int.from_bytes(data[pos+1:pos+4], 'little'); pos += 4
        raw += unsnappy(data[pos:pos+size]); pos += size
    records = []; pos = 0
    while pos < len(raw):
        size, pos = varint(raw, pos)
        header = Message(raw[pos:pos+size]); pos += size
        objects = []
        for info in header.all(2):
            size = Message(info).get(3)
            objects.append(Message(raw[pos:pos+size])); pos += size
        records.append([header, objects])
    if pos != len(raw): raise ValueError('IWA 对象长度不一致')
    return records


def pack_iwa(records):
    raw = bytearray()
    for header, objects in records:
        h = copy.deepcopy(header)
        infos = [f for f in h.fields if f[0] == 2]
        for info_field, obj in zip(infos, objects):
            info = Message(info_field[2]); info.set(3, 0, len(obj.pack()))
            info_field[2] = info.pack()
        head = h.pack(); raw += vint(len(head)) + head
        for obj in objects: raw += obj.pack()
    out = bytearray()
    for pos in range(0, len(raw), 65536):
        block = raw[pos:pos+65536]; length = len(block) - 1
        if length < 60:
            literal = bytes([length << 2])
        else:
            count = (length.bit_length()+7)//8
            literal = bytes([(59+count) << 2]) + length.to_bytes(count, 'little')
        packed = vint(len(block)) + literal + block
        out += b'\0' + len(packed).to_bytes(3, 'little') + packed
    return bytes(out)


def objects_from(records):
    return {h.get(1): oo[0] for h, oo in records if len(oo) == 1}


def xy(message): return [message.f(1), message.f(2)]


def point(x, y):
    m = Message(); m.sf(1, x); m.sf(2, y)
    return m



# Telegram MTProto - the hot inner loops, compiled once per process.
#
# Pure PowerShell is the rule in this client; the exceptions are the loops where it is simply
# too slow: AES-IGE block chaining, the little-endian TL byte reader/writer, PBKDF2 (100000
# HMAC rounds for the 2FA password) and the Pollard-Brent factoring of the handshake's pq.
# Nothing here knows about Telegram's schema or protocol - it is arithmetic and byte shuffling.
#
# The source must compile under the C# 5 compiler Windows PowerShell 5.1 ships and under
# pwsh 7: no string interpolation, no `?.`, no expression-bodied members, no tuples, no
# out-variable declarations. Hence the plain, slightly old-fashioned C# below.

if ($PSVersionTable.PSVersion.Major -lt 6) { Add-Type -AssemblyName System.Numerics }

if (-not ('DlTg.TlWriter' -as [type])) {
    $tgNativeSource = @'
using System;
using System.IO;
using System.Numerics;
using System.Security.Cryptography;
using System.Text;

namespace DlTg
{
    // Append-only little-endian TL serializer.
    public class TlWriter
    {
        private MemoryStream ms = new MemoryStream();

        public int Length { get { return (int)ms.Length; } }

        public void WriteInt(int v) { ms.Write(BitConverter.GetBytes(v), 0, 4); }
        public void WriteLong(long v) { ms.Write(BitConverter.GetBytes(v), 0, 8); }
        public void WriteDouble(double v) { ms.Write(BitConverter.GetBytes(v), 0, 8); }
        public void WriteRaw(byte[] b) { ms.Write(b, 0, b.Length); }

        // TL string/bytes: 1-byte length (or 0xFE + 3-byte length), payload, zero pad to 4.
        public void WriteBytes(byte[] b)
        {
            int len = b.Length;
            int head;
            if (len < 254)
            {
                ms.WriteByte((byte)len);
                head = 1;
            }
            else
            {
                ms.WriteByte(254);
                ms.WriteByte((byte)(len & 0xFF));
                ms.WriteByte((byte)((len >> 8) & 0xFF));
                ms.WriteByte((byte)((len >> 16) & 0xFF));
                head = 4;
            }
            ms.Write(b, 0, len);
            int pad = (4 - ((head + len) % 4)) % 4;
            for (int i = 0; i < pad; i++) ms.WriteByte(0);
        }

        public void WriteString(string s) { WriteBytes(Encoding.UTF8.GetBytes(s)); }

        public byte[] ToArray() { return ms.ToArray(); }
    }

    // Cursor over a byte[] with the TL primitive reads.
    public class TlReader
    {
        private byte[] buf;
        private int pos;
        private int end;

        public TlReader(byte[] data) { buf = data; pos = 0; end = data.Length; }
        public TlReader(byte[] data, int offset, int count) { buf = data; pos = offset; end = offset + count; }

        public int Position { get { return pos; } set { pos = value; } }
        public int Remaining { get { return end - pos; } }

        private void Need(int n)
        {
            if (n < 0 || pos + n > end)
                throw new InvalidDataException("TL reader: need " + n + " bytes at " + pos + ", only " + (end - pos) + " left");
        }

        public int ReadInt() { Need(4); int v = BitConverter.ToInt32(buf, pos); pos += 4; return v; }
        public int PeekInt() { Need(4); return BitConverter.ToInt32(buf, pos); }
        public long ReadLong() { Need(8); long v = BitConverter.ToInt64(buf, pos); pos += 8; return v; }
        public double ReadDouble() { Need(8); double v = BitConverter.ToDouble(buf, pos); pos += 8; return v; }

        public byte[] ReadRaw(int n)
        {
            Need(n);
            byte[] r = new byte[n];
            Buffer.BlockCopy(buf, pos, r, 0, n);
            pos += n;
            return r;
        }

        public byte[] ReadBytes()
        {
            Need(1);
            int len = buf[pos];
            int head = 1;
            if (len >= 254)
            {
                Need(4);
                len = buf[pos + 1] | (buf[pos + 2] << 8) | (buf[pos + 3] << 16);
                head = 4;
            }
            pos += head;
            byte[] r = ReadRaw(len);
            int pad = (4 - ((head + len) % 4)) % 4;
            Need(pad);
            pos += pad;
            return r;
        }

        public string ReadString() { return Encoding.UTF8.GetString(ReadBytes()); }
    }

    // AES-IGE over AES-ECB (no padding). Works for any AES key size.
    public static class Ige
    {
        private static void Check(byte[] data, byte[] iv)
        {
            if (data.Length % 16 != 0) throw new ArgumentException("IGE data must be a multiple of 16 bytes");
            if (iv.Length != 32) throw new ArgumentException("IGE iv must be 32 bytes");
        }

        private static Aes NewAes(byte[] key)
        {
            Aes aes = Aes.Create();
            aes.Mode = CipherMode.ECB;
            aes.Padding = PaddingMode.None;
            aes.Key = key;
            return aes;
        }

        // c_i = E(p_i xor c_{i-1}) xor p_{i-1};  iv = c_0 | p_0
        public static byte[] Encrypt(byte[] data, byte[] key, byte[] iv)
        {
            Check(data, iv);
            byte[] outp = new byte[data.Length];
            byte[] prevC = new byte[16];
            byte[] prevP = new byte[16];
            Buffer.BlockCopy(iv, 0, prevC, 0, 16);
            Buffer.BlockCopy(iv, 16, prevP, 0, 16);
            byte[] x = new byte[16];
            byte[] e = new byte[16];
            using (Aes aes = NewAes(key))
            using (ICryptoTransform enc = aes.CreateEncryptor())
            {
                for (int off = 0; off < data.Length; off += 16)
                {
                    for (int i = 0; i < 16; i++) x[i] = (byte)(data[off + i] ^ prevC[i]);
                    enc.TransformBlock(x, 0, 16, e, 0);
                    for (int i = 0; i < 16; i++) prevC[i] = (byte)(e[i] ^ prevP[i]);
                    Buffer.BlockCopy(prevC, 0, outp, off, 16);
                    Buffer.BlockCopy(data, off, prevP, 0, 16);
                }
            }
            return outp;
        }

        // p_i = D(c_i xor p_{i-1}) xor c_{i-1}
        public static byte[] Decrypt(byte[] data, byte[] key, byte[] iv)
        {
            Check(data, iv);
            byte[] outp = new byte[data.Length];
            byte[] prevC = new byte[16];
            byte[] prevP = new byte[16];
            Buffer.BlockCopy(iv, 0, prevC, 0, 16);
            Buffer.BlockCopy(iv, 16, prevP, 0, 16);
            byte[] x = new byte[16];
            byte[] d = new byte[16];
            using (Aes aes = NewAes(key))
            using (ICryptoTransform dec = aes.CreateDecryptor())
            {
                for (int off = 0; off < data.Length; off += 16)
                {
                    for (int i = 0; i < 16; i++) x[i] = (byte)(data[off + i] ^ prevP[i]);
                    dec.TransformBlock(x, 0, 16, d, 0);
                    for (int i = 0; i < 16; i++) prevP[i] = (byte)(d[i] ^ prevC[i]);
                    Buffer.BlockCopy(prevP, 0, outp, off, 16);
                    Buffer.BlockCopy(data, off, prevC, 0, 16);
                }
            }
            return outp;
        }
    }

    // Big-endian <-> BigInteger, PBKDF2 and the pq factoring.
    public static class Bn
    {
        public static BigInteger FromBigEndian(byte[] b)
        {
            byte[] le = new byte[b.Length + 1];
            for (int i = 0; i < b.Length; i++) le[i] = b[b.Length - 1 - i];
            return new BigInteger(le);
        }

        // Big-endian, left padded to `length` (0 = minimal). Throws if the value does not fit.
        public static byte[] ToBigEndian(BigInteger v, int length)
        {
            byte[] le = v.ToByteArray();
            int n = le.Length;
            while (n > 1 && le[n - 1] == 0) n--;
            if (length > 0 && n > length) throw new ArgumentException("value does not fit in " + length + " bytes");
            int size = length > 0 ? length : n;
            byte[] r = new byte[size];
            for (int i = 0; i < n; i++) r[size - 1 - i] = le[i];
            return r;
        }

        // PBKDF2-HMAC-SHA512, written out so it behaves the same on every runtime.
        public static byte[] Pbkdf2Sha512(byte[] password, byte[] salt, int iterations, int dkLen)
        {
            int hLen = 64;
            int blocks = (dkLen + hLen - 1) / hLen;
            byte[] dk = new byte[blocks * hLen];
            using (HMACSHA512 hmac = new HMACSHA512(password))
            {
                for (int block = 1; block <= blocks; block++)
                {
                    byte[] first = new byte[salt.Length + 4];
                    Buffer.BlockCopy(salt, 0, first, 0, salt.Length);
                    first[salt.Length] = (byte)(block >> 24);
                    first[salt.Length + 1] = (byte)(block >> 16);
                    first[salt.Length + 2] = (byte)(block >> 8);
                    first[salt.Length + 3] = (byte)block;
                    byte[] u = hmac.ComputeHash(first);
                    byte[] t = (byte[])u.Clone();
                    for (int i = 1; i < iterations; i++)
                    {
                        u = hmac.ComputeHash(u);
                        for (int j = 0; j < hLen; j++) t[j] ^= u[j];
                    }
                    Buffer.BlockCopy(t, 0, dk, (block - 1) * hLen, hLen);
                }
            }
            byte[] res = new byte[dkLen];
            Buffer.BlockCopy(dk, 0, res, 0, dkLen);
            return res;
        }

        // Pollard-Brent. Returns a non-trivial factor of n (n odd composite), or 0 on failure.
        private static BigInteger Brent(BigInteger n, BigInteger c, BigInteger y0, BigInteger m)
        {
            BigInteger y = y0, r = 1, q = 1, g = 1, x = 0, ys = 0;
            do
            {
                x = y;
                for (BigInteger i = 0; i < r; i++) y = (y * y + c) % n;
                BigInteger k = 0;
                do
                {
                    ys = y;
                    BigInteger lim = BigInteger.Min(m, r - k);
                    for (BigInteger i = 0; i < lim; i++)
                    {
                        y = (y * y + c) % n;
                        q = (q * BigInteger.Abs(x - y)) % n;
                    }
                    g = BigInteger.GreatestCommonDivisor(q, n);
                    k += m;
                } while (k < r && g == 1);
                r *= 2;
            } while (g == 1);
            if (g == n)
            {
                do
                {
                    ys = (ys * ys + c) % n;
                    g = BigInteger.GreatestCommonDivisor(BigInteger.Abs(x - ys), n);
                } while (g == 1);
            }
            return g == n ? BigInteger.Zero : g;
        }

        // Smaller factor first: p < q, p * q == pq.
        public static ulong[] FactorPq(ulong pq)
        {
            BigInteger n = pq;
            if (n < 4) throw new ArgumentException("pq too small");
            if (n.IsEven) return new ulong[] { 2, (ulong)(n / 2) };
            Random rnd = new Random(12345);
            for (int attempt = 0; attempt < 64; attempt++)
            {
                BigInteger c = 1 + rnd.Next(1, 1000000);
                BigInteger y0 = 1 + rnd.Next(1, 1000000);
                BigInteger f = Brent(n, c, y0, 128);
                if (f > 1 && f < n)
                {
                    BigInteger other = n / f;
                    ulong a = (ulong)f;
                    ulong b = (ulong)other;
                    return a < b ? new ulong[] { a, b } : new ulong[] { b, a };
                }
            }
            throw new InvalidOperationException("pq factorisation failed");
        }
    }
}
'@
    $tgRefs = @([System.Numerics.BigInteger].Assembly.Location)
    Add-Type -TypeDefinition $tgNativeSource -ReferencedAssemblies $tgRefs
    Remove-Variable tgNativeSource, tgRefs -ErrorAction SilentlyContinue
}

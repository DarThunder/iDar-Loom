local krng = {}

local band = bit32.band
local bnot = bit32.bnot
local bxor = bit32.bxor
local lshift = bit32.lshift
local rshift = bit32.rshift
local spack = string.pack
local sunpack = string.unpack

local rng_state = {
    key = nil,
    counter = 0,
    buffer = ""
}

local H = {
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
}
local K = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
    0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
    0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
    0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
    0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
    0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
}

local MOD32 = 0x100000000
local B = 64

local function rotr32(value, bits)
    value = value % MOD32
    local r = (rshift(value, bits) + lshift(value, 32 - bits)) % MOD32
    return r
end

local function to32(x)
    return x % MOD32
end

local function sha256_compress(chunk, H_copy)
    local W = {}
    for i = 1, 16 do
        W[i] = to32(chunk[i] or 0)
    end
    for i = 17, 64 do
        local w15 = W[i-15]
        local w2  = W[i-2]
        local s0 = bxor(bxor(rotr32(w15, 7), rotr32(w15, 18)), rshift(w15, 3))
        local s1 = bxor(bxor(rotr32(w2, 17), rotr32(w2, 19)), rshift(w2, 10))
        W[i] = to32(W[i-16] + s0 + W[i-7] + s1)
    end

    local a, b, c, d, e, f, g, h = table.unpack(H_copy)

    for i = 1, 64 do
        local S1 = bxor(bxor(rotr32(e, 6), rotr32(e, 11)), rotr32(e, 25))
        local ch = bxor(band(e,f), band(bnot(e), g))
        local temp1 = to32(h + S1 + ch + K[i] + W[i])
        local S0 = bxor(bxor(rotr32(a, 2), rotr32(a, 13)), rotr32(a, 22))
        local maj = bxor(bxor(band(a, b), band(a, c)), band(b, c))
        local temp2 = to32(S0 + maj)

        h = g
        g = f
        f = e
        e = to32(d + temp1)
        d = c
        c = b
        b = a
        a = to32(temp1 + temp2)
    end

    local t = {a,b,c,d,e,f,g,h}
    for i = 1, 8 do
        H_copy[i] = to32(H_copy[i] + t[i])
    end
end

function krng.sha256(message)
    local message_len = #message
    local padded_message = message .. "\128"
    while (#padded_message % 64) ~= 56 do
        padded_message = padded_message .. "\0"
    end

    padded_message = padded_message .. spack(">I8", message_len * 8)

    local H_copy = {table.unpack(H)}
    for pos = 1, #padded_message, 64 do
        local block = padded_message:sub(pos, pos + 63)
        local a,b,c,d,e,f,g,h,i,j,k,l,m,n,o,p = sunpack(">I4I4I4I4I4I4I4I4I4I4I4I4I4I4I4I4", block)
        local chunk = {a,b,c,d,e,f,g,h,i,j,k,l,m,n,o,p}
        sha256_compress(chunk, H_copy)
    end

    local digest_hex = ""
    local digest_bin = ""
    for i = 1, 8 do
        digest_bin = digest_bin .. spack(">I4", H_copy[i]) 
        digest_hex = digest_hex .. string.format("%08x", H_copy[i])
    end
    return digest_hex, digest_bin
end

local function derive_key(secret)
    local _, bin = krng.sha256(secret)
    return bin
end

local function operate(message, secret, nonce, initial_counter)
    if not message or not secret or not nonce then return nil end

    local key = derive_key(secret)
    local k1, k2, k3, k4, k5, k6, k7, k8 = sunpack("<I4I4I4I4I4I4I4I4", key)
    local n1, n2, n3 = sunpack("<I4I4I4", nonce)

    local out = {}
    local counter = initial_counter or 1
    local pos = 1
    local msg_len = #message
    local s1, s2, s3, s4 = 0x61707865, 0x3320646e, 0x79622d32, 0x6b206574

    while pos <= msg_len do
        local x1, x2, x3, x4 = s1, s2, s3, s4
        local x5, x6, x7, x8 = k1, k2, k3, k4
        local x9, x10, x11, x12 = k5, k6, k7, k8
        local x13, x14, x15, x16 = counter, n1, n2, n3

        for _ = 1, 10 do
            x1 = (x1 + x5) % MOD32; x13 = bxor(x13, x1); x13 = bxor(lshift(x13, 16), rshift(x13, 16))
            x9 = (x9 + x13) % MOD32; x5 = bxor(x5, x9); x5 = bxor(lshift(x5, 12), rshift(x5, 20))
            x1 = (x1 + x5) % MOD32; x13 = bxor(x13, x1); x13 = bxor(lshift(x13, 8), rshift(x13, 24))
            x9 = (x9 + x13) % MOD32; x5 = bxor(x5, x9); x5 = bxor(lshift(x5, 7), rshift(x5, 25))

            x2 = (x2 + x6) % MOD32; x14 = bxor(x14, x2); x14 = bxor(lshift(x14, 16), rshift(x14, 16))
            x10 = (x10 + x14) % MOD32; x6 = bxor(x6, x10); x6 = bxor(lshift(x6, 12), rshift(x6, 20))
            x2 = (x2 + x6) % MOD32; x14 = bxor(x14, x2); x14 = bxor(lshift(x14, 8), rshift(x14, 24))
            x10 = (x10 + x14) % MOD32; x6 = bxor(x6, x10); x6 = bxor(lshift(x6, 7), rshift(x6, 25))

            x3 = (x3 + x7) % MOD32; x15 = bxor(x15, x3); x15 = bxor(lshift(x15, 16), rshift(x15, 16))
            x11 = (x11 + x15) % MOD32; x7 = bxor(x7, x11); x7 = bxor(lshift(x7, 12), rshift(x7, 20))
            x3 = (x3 + x7) % MOD32; x15 = bxor(x15, x3); x15 = bxor(lshift(x15, 8), rshift(x15, 24))
            x11 = (x11 + x15) % MOD32; x7 = bxor(x7, x11); x7 = bxor(lshift(x7, 7), rshift(x7, 25))

            x4 = (x4 + x8) % MOD32; x16 = bxor(x16, x4); x16 = bxor(lshift(x16, 16), rshift(x16, 16))
            x12 = (x12 + x16) % MOD32; x8 = bxor(x8, x12); x8 = bxor(lshift(x8, 12), rshift(x8, 20))
            x4 = (x4 + x8) % MOD32; x16 = bxor(x16, x4); x16 = bxor(lshift(x16, 8), rshift(x16, 24))
            x12 = (x12 + x16) % MOD32; x8 = bxor(x8, x12); x8 = bxor(lshift(x8, 7), rshift(x8, 25))

            x1 = (x1 + x6) % MOD32; x16 = bxor(x16, x1); x16 = bxor(lshift(x16, 16), rshift(x16, 16))
            x11 = (x11 + x16) % MOD32; x6 = bxor(x6, x11); x6 = bxor(lshift(x6, 12), rshift(x6, 20))
            x1 = (x1 + x6) % MOD32; x16 = bxor(x16, x1); x16 = bxor(lshift(x16, 8), rshift(x16, 24))
            x11 = (x11 + x16) % MOD32; x6 = bxor(x6, x11); x6 = bxor(lshift(x6, 7), rshift(x6, 25))

            x2 = (x2 + x7) % MOD32; x13 = bxor(x13, x2); x13 = bxor(lshift(x13, 16), rshift(x13, 16))
            x12 = (x12 + x13) % MOD32; x7 = bxor(x7, x12); x7 = bxor(lshift(x7, 12), rshift(x7, 20))
            x2 = (x2 + x7) % MOD32; x13 = bxor(x13, x2); x13 = bxor(lshift(x13, 8), rshift(x13, 24))
            x12 = (x12 + x13) % MOD32; x7 = bxor(x7, x12); x7 = bxor(lshift(x7, 7), rshift(x7, 25))

            x3 = (x3 + x8) % MOD32; x14 = bxor(x14, x3); x14 = bxor(lshift(x14, 16), rshift(x14, 16))
            x9 = (x9 + x14) % MOD32; x8 = bxor(x8, x9); x8 = bxor(lshift(x8, 12), rshift(x8, 20))
            x3 = (x3 + x8) % MOD32; x14 = bxor(x14, x3); x14 = bxor(lshift(x14, 8), rshift(x14, 24))
            x9 = (x9 + x14) % MOD32; x8 = bxor(x8, x9); x8 = bxor(lshift(x8, 7), rshift(x8, 25))

            x4 = (x4 + x5) % MOD32; x15 = bxor(x15, x4); x15 = bxor(lshift(x15, 16), rshift(x15, 16))
            x10 = (x10 + x15) % MOD32; x5 = bxor(x5, x10); x5 = bxor(lshift(x5, 12), rshift(x5, 20))
            x4 = (x4 + x5) % MOD32; x15 = bxor(x15, x4); x15 = bxor(lshift(x15, 8), rshift(x15, 24))
            x10 = (x10 + x15) % MOD32; x5 = bxor(x5, x10); x5 = bxor(lshift(x5, 7), rshift(x5, 25))
        end

        x1 = (x1 + s1) % MOD32; x2 = (x2 + s2) % MOD32; x3 = (x3 + s3) % MOD32; x4 = (x4 + s4) % MOD32
        x5 = (x5 + k1) % MOD32; x6 = (x6 + k2) % MOD32; x7 = (x7 + k3) % MOD32; x8 = (x8 + k4) % MOD32
        x9 = (x9 + k5) % MOD32; x10 = (x10 + k6) % MOD32; x11 = (x11 + k7) % MOD32; x12 = (x12 + k8) % MOD32
        x13 = (x13 + counter) % MOD32; x14 = (x14 + n1) % MOD32; x15 = (x15 + n2) % MOD32; x16 = (x16 + n3) % MOD32

        if msg_len - pos >= 63 then
            local m1, m2, m3, m4, m5, m6, m7, m8, m9, m10, m11, m12, m13, m14, m15, m16 = sunpack("<I4I4I4I4I4I4I4I4I4I4I4I4I4I4I4I4", message, pos)
            out[#out + 1] = spack("<I4I4I4I4I4I4I4I4I4I4I4I4I4I4I4I4", 
                bxor(x1, m1), bxor(x2, m2), bxor(x3, m3), bxor(x4, m4),
                bxor(x5, m5), bxor(x6, m6), bxor(x7, m7), bxor(x8, m8),
                bxor(x9, m9), bxor(x10, m10), bxor(x11, m11), bxor(x12, m12),
                bxor(x13, m13), bxor(x14, m14), bxor(x15, m15), bxor(x16, m16)
            )
            pos = pos + 64
        else
            local keystream = spack("<I4I4I4I4I4I4I4I4I4I4I4I4I4I4I4I4", x1, x2, x3, x4, x5, x6, x7, x8, x9, x10, x11, x12, x13, x14, x15, x16)
            local rem = msg_len - pos + 1
            for i = 1, rem do
                out[#out + 1] = string.char(bxor(string.byte(message, pos + i - 1), string.byte(keystream, i)))
            end
            pos = pos + rem
        end

        counter = (counter + 1) % MOD32
    end

    return table.concat(out)
end

function krng.encrypt(message, secret, nonce)
    return operate(message, secret, nonce)
end

local pools = {}
for i = 1, 32 do pools[i] = "" end
local reseed_count = 0
local pool_index = 0

local function fortuna_reseed()
    reseed_count = reseed_count + 1
    local material = ""

    for i = 1, 32 do
        if reseed_count % (2^i) == 0 then
            local _, h = krng.sha256(pools[i])
            material = material .. h
            pools[i] = ""
        end
    end

    local _, new_key = krng.sha256(rng_state.key .. material)
    rng_state.key = new_key
    rng_state.counter = 0
end

function krng.add_entropy(event_data)
    pool_index = (pool_index % 32) + 1
    pools[pool_index] = pools[pool_index] .. event_data

    if #pools[1] >= 64 then
        fortuna_reseed()
    end
end

local function gather_entropy()
    local samples = {}

    table.insert(samples, tostring(os.epoch("utc")))
    table.insert(samples, tostring(os.epoch("ingame")))
    table.insert(samples, tostring(os.epoch("local")))

    for _ = 1, 3 do
        local t1 = os.clock()
        for _ = 1, math.random(50, 200) do
            math.random()
        end
        local t2 = os.clock()
        table.insert(samples, tostring(math.floor((t2-t1) * 1e9)))
    end

    table.insert(samples, tostring(os.getComputerID()))

    local _, seed1 = krng.sha256(table.concat(samples, ":"))
    local _, seed2 = krng.sha256(seed1 .. table.concat(samples, "|"))
    local _, seed3 = krng.sha256(seed2 .. seed1)

    return seed3
end

local function reseed_rng()
    local raw = gather_entropy()
    if rng_state.key then
        raw = raw .. rng_state.key
    end

    local _, bin_hash = krng.sha256(raw)
    rng_state.key = bin_hash
    rng_state.counter = 0
end

function krng.read_random_bytes(num_bytes)
    if not rng_state.key then reseed_rng() end

    while #rng_state.buffer < num_bytes do
        local nonce = string.rep("\0", 8) .. spack(">I4", rng_state.counter)

        local zeros = string.rep("\0", 64)
        local keystream_block = krng.encrypt(zeros, rng_state.key, nonce)

        rng_state.buffer = rng_state.buffer .. keystream_block
        rng_state.counter = rng_state.counter + 1

        if rng_state.counter % 1024 == 0 then reseed_rng() end
    end

    local result = rng_state.buffer:sub(1, num_bytes)
    rng_state.buffer = rng_state.buffer:sub(num_bytes + 1)

    return result
end

krng.read_random_bytes(1)

return krng
#include "Pairing.h"

#include <cstring>

namespace atvm {

namespace {
Bytes Str(const char* s) { return Bytes(s, s + strlen(s)); }
}  // namespace

uint8_t RoleChar(Role r) { return r == Role::Mac ? PairingConst::kTagMac : PairingConst::kTagTv; }
const char* RoleName(Role r) { return r == Role::Mac ? "mac" : "tv"; }
const char* ChannelName(Channel c) { return c == Channel::Control ? "ctl" : "rev"; }

Bytes Th0(const Bytes& pkSelf, const Bytes& pkPeer) {
    return Sha256({Str("atvm-pair-v2"), pkSelf, pkPeer});
}

Bytes CommitKey(const Bytes& dh, const Bytes& th0) {
    return HkdfSha256(dh, th0, "atvm-pk-commit-v2");
}

Bytes Commitment(const Bytes& kc, Role role, int round, uint8_t bit, const Bytes& nonce) {
    return HmacSha256(kc, {Bytes{RoleChar(role), (uint8_t)round, bit}, nonce});
}

Bytes PairingKey(const Bytes& dh, const Bytes& th) { return HkdfSha256(dh, th, "atvm-pair-v2"); }

Bytes Confirm(const Bytes& key, Role role, const Bytes& th) {
    return HmacSha256(key, {Str(("atvm-confirm-v2|" + std::string(RoleName(role))).c_str()), th});
}

Bytes SessionProof(const Bytes& key, Channel channel, Role role, const Bytes& serverNonce,
                   const Bytes& clientNonce) {
    const std::string tag =
        std::string("atvm-auth-v2|") + ChannelName(channel) + "|" + RoleName(role);
    return HmacSha256(key, {Str(tag.c_str()), serverNonce, clientNonce});
}

std::string Fingerprint(const Bytes& key) {
    Bytes h = Sha256({Str("atvm-fp-v2"), key});
    if (h.size() < 4) return {};
    return BytesToHex(Bytes(h.begin(), h.begin() + 4));
}

uint8_t PasskeyBit(uint32_t passkey, int i) { return (uint8_t)((passkey >> i) & 1u); }

bool PasskeyFromText(const std::string& text, uint32_t& out) {
    if (text.size() != 6) return false;
    uint32_t v = 0;
    for (char c : text) {
        if (c < '0' || c > '9') return false;
        v = v * 10u + (uint32_t)(c - '0');
    }
    out = v;
    return true;
}

PasskeyInitiator::PasskeyInitiator(uint32_t passkey, std::function<Bytes()> nonce)
    : ephemeral_(EcdhKey::Generate()), passkey_(passkey),
      nonce_(nonce ? nonce : [] { return RandomBytes(16); }) {
    selfPublic_ = ephemeral_.publicX963();
}

PasskeyInitiator::PasskeyInitiator(uint32_t passkey, EcdhKey&& fixedKey,
                                   std::function<Bytes()> nonce)
    : ephemeral_(std::move(fixedKey)), passkey_(passkey),
      nonce_(nonce ? nonce : [] { return RandomBytes(16); }) {
    selfPublic_ = ephemeral_.publicX963();
}

Msg PasskeyInitiator::initMessage() const {
    Msg m("pair_init");
    m.text["pk"] = B64Encode(selfPublic_);
    return m;
}

Msg PasskeyInitiator::commitMessage() {
    na_ = nonce_();
    ca_ = Commitment(kc_, Role::Mac, round_, PasskeyBit(passkey_, round_), na_);
    phase_ = Phase::AwaitingCommit;
    Msg m("pk_commit");
    m.number["i"] = round_;
    m.text["c"] = B64Encode(ca_);
    return m;
}

PasskeyInitiator::Failure PasskeyInitiator::handle(const Msg& m, Msg& out) {
    out = Msg();
    const std::string t = m.type();

    if (t == "denied") {
        phase_ = Phase::Done;
        const std::string reason = m.str("reason");
        if (reason == "pin_mismatch" || reason == "pin_expired")
            return {Error::PinRejected, reason, 0};
        if (reason == "locked")
            return {Error::Locked, reason, m.num("retry_after_ms", 0)};
        return {Error::Denied, reason.empty() ? "?" : reason, 0};
    }

    switch (phase_) {
    case Phase::AwaitingKey: {
        if (t != "pair_key") return {Error::Unexpected, t, 0};
        const Bytes peer = B64Decode(m.str("pk"));
        // Eğri dışı nokta ve kendi anahtarının yansıtılması burada reddedilir (§3.2).
        if (peer.empty() || !ephemeral_.SecretWith(peer, dh_))
            return {Error::BadPeerKey, t, 0};
        const Bytes th0 = Th0(selfPublic_, peer);
        kc_ = CommitKey(dh_, th0);
        transcript_ = th0;
        round_ = 0;
        out = commitMessage();
        return {Error::None, {}, 0};
    }
    case Phase::AwaitingCommit: {
        if (t != "pk_commit") return {Error::Unexpected, t, 0};
        const Bytes c = B64Decode(m.str("c"));
        if (m.num("i", -1) != round_ || c.size() != 32)
            return {Error::Unexpected, t + " tur " + std::to_string(round_), 0};
        cb_ = c;
        phase_ = Phase::AwaitingOpen;
        out = Msg("pk_open");
        out.number["i"] = round_;
        out.text["n"] = B64Encode(na_);       // kendi taahhüdümüzün nonce'unu açıyoruz
        return {Error::None, {}, 0};
    }
    case Phase::AwaitingOpen: {
        if (t != "pk_open") return {Error::Unexpected, t, 0};
        const Bytes nb = B64Decode(m.str("n"));
        if (m.num("i", -1) != round_ || nb.size() != PairingConst::kNonceBytes)
            return {Error::Unexpected, t + " tur " + std::to_string(round_), 0};
        // TV'nin taahhüdü, bizim açtığımız bitle tutmalı: araya giren bit başına yakalanır.
        const Bytes want = Commitment(kc_, Role::Tv, round_, PasskeyBit(passkey_, round_), nb);
        if (!ConstantTimeEqual(want, cb_)) {
            phase_ = Phase::Done;
            return {Error::PeerProofInvalid, t, 0};
        }
        transcript_.insert(transcript_.end(), ca_.begin(), ca_.end());
        transcript_.insert(transcript_.end(), cb_.begin(), cb_.end());
        transcript_.insert(transcript_.end(), na_.begin(), na_.end());
        transcript_.insert(transcript_.end(), nb.begin(), nb.end());
        ++round_;
        if (round_ < PairingConst::kRounds) {
            out = commitMessage();
            return {Error::None, {}, 0};
        }
        th_ = Sha256({transcript_});
        pairingKey_ = PairingKey(dh_, th_);
        phase_ = Phase::AwaitingPaired;
        // Kullanıcı PIN'i girmeden buraya gelinmez: yayıncının onayı ancak şimdi gider (§3.2).
        out = Msg("pair_confirm");
        out.text["mac"] = B64Encode(Confirm(pairingKey_, Role::Mac, th_));
        return {Error::None, {}, 0};
    }
    case Phase::AwaitingPaired: {
        if (t != "paired") return {Error::Unexpected, t, 0};
        const Bytes mac = B64Decode(m.str("mac"));
        if (!ConstantTimeEqual(mac, Confirm(pairingKey_, Role::Tv, th_))) {
            phase_ = Phase::Done;
            return {Error::PeerProofInvalid, t, 0};
        }
        phase_ = Phase::Done;                 // out boş: eşleşme tamam
        return {Error::None, {}, 0};
    }
    case Phase::Done:
        return {Error::Unexpected, t, 0};
    }
    return {Error::Unexpected, t, 0};
}

}  // namespace atvm

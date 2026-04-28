# preflight

iOS release-readiness preflight check — 22 statik analiz kuralı, terminal + web dashboard.

Live'a çıkmadan önce kod kalitesi ve App Store submission engellerini yakalar:
hardcoded `print`, `try!`/`fatalError`, `http://` URL, hassas veri pasteboard'a kopyalama,
ATS exception, eksik privacy manifest, deprecated iOS API, retain cycle riski olan closure'lar
ve daha fazlası.

## Kurulum

```bash
brew tap ersel95/tap
brew install preflight
```

> Tap henüz public değilse, formula dosyasını doğrudan kullanabilirsin:
> `brew install --HEAD https://raw.githubusercontent.com/ersel95/ios-preflight-security/main/Formula/preflight.rb`

## Kullanım

Herhangi bir iOS proje kökünde:

```bash
preflight                  # terminalde tarama, ERR varsa exit 1
preflight dashboard        # tarayıcıda interaktif dashboard (http://localhost:7474)
preflight doctor           # bağımlılık check
preflight --help
```

İlk koşuda repo kökünde `.preflight/` cache klasörü oluşur — kendi `.gitignore`'una ekle.

### Options

```
preflight [scan]           # default subcommand
    --strict               WARN'lar da fail döner (CI için)
    --report FILE          Markdown rapor üret
    --json FILE            JSON çıktı üret
    --only print,todo      Sadece bu kuralları çalıştır
    --skip ats,mock        Bu kuralları atla
    --src "MyApp"          Kaynak klasör override
    --target MyApp         Xcode target (introspection)
    --config Release       Build configuration (introspection)
```

## Kontrol edilen 22 kural

| # | Kural | Severity | Ne yapar |
|---|-------|----------|----------|
| 1 | `print` | ERR | `print/NSLog/debugPrint/dump`; `#if !PROD`/`#if DEBUG` blokları istisna |
| 2 | `unsafe` | WARN | `try!`, `fatalError(...)`, `as!` force-cast |
| 3 | `todo` | WARN | `// TODO`, `// FIXME`, `// HACK`, `// XXX` |
| 4 | `http` | ERR | `http://`, `localhost`, private IP referansları |
| 5 | `secrets` | WARN | `apiKey/password/token/secret = "..."` 16+ char hardcoded |
| 6 | `mock` | WARN | `*Mock*.swift` / `*Stub*.swift` Prod target sızıntısı |
| 7 | `ats` | ERR | Info.plist `NSAllowsArbitraryLoads` ve ATS exception'ları |
| 8 | `env` | WARN | `.test.`, `.uat.`, `staging.` URL parçaları |
| 9 | `commented` | WARN | 3+ satır yorum-satırına alınmış kod |
| 10 | `lint` | INFO | `// swiftlint:disable` bildirimleri |
| 11 | `plist` | ERR | iOS izinleri için Info.plist usage description eksikliği |
| 12 | `config` | ERR/WARN | `Prod.xcconfig` `test/uat/dev` sızıntısı veya eksik temel ayarlar |
| 13 | `assets` | WARN | `Image("...")` referansının xcassets'te bulunmaması |
| 14 | `privacy-manifest` | ERR | `PrivacyInfo.xcprivacy` + Required Reason API tag'leri |
| 15 | `sdk` | ERR/WARN | iOS deployment target & Xcode versiyonu |
| 16 | `weak-self` | WARN | `Task`/`.sink`/`.receive` closure'larında `[weak self]` eksikliği |
| 17 | `weak-delegate` | WARN | `var delegate:` declaration'ında `weak` modifier eksikliği |
| 18 | `pasteboard` | ERR/WARN | `UIPasteboard` ile hassas veri kopyalama |
| 19 | `sensitive-log` | ERR | Log fonksiyonuna `password/pin/cvv/cardNo/otp/token` geçirme |
| 20 | `deprecated` | WARN | iOS 16+ deprecated API'lar (UIScreen.main, UIApplication.shared.windows, vb.) |
| 21 | `hardcoded-string` | WARN | L10n enum dışı insan-okunaklı string'ler |
| 22 | `git` | WARN/INFO | Uncommitted/untracked dosya, branch upstream durumu |

## `.preflightignore`

Repo kökünde, satır başına bir substring kalıbı (içeren dosya yolları tüm kurallarda atlanır):

```
# auto-generated mocks
APIMocks.swift

# legacy file (refactor planlanıyor)
RuntimeProtection.swift
```

## CI entegrasyonu

```yaml
- name: Preflight
  run: preflight --strict --report preflight.md
- uses: actions/upload-artifact@v4
  if: always()
  with: { name: preflight, path: preflight.md }
```

`--strict` ile WARN'lar da CI'ı kırar.

## Geliştirme (brew olmadan)

```bash
git clone https://github.com/ersel95/ios-preflight-security
cd /path/to/your/ios/project
PATH="/path/to/ios-preflight-security/bin:$PATH" preflight dashboard
```

## Lisans

MIT — `LICENSE` dosyasına bak.

# Plan: Pinned Bottom Input (Claude-Code-style)

Goal: prompt/cursor always di baris paling bawah terminal. Command output selalu
muncul DI ATAS nya, area atas discroll, input box bawah tetep diem — kayak UI
Claude Code sendiri.

## Kenapa ini beda dari yang udah ada

Boxed-prompt sekarang (border atas+bawah per `read -e` call) itu ilusi statis
per-giliran doang — digambar ulang tiap loop, gak beneran "pinned" selama
proses jalan/nunggu output panjang. Yang diminta sekarang: true split-pane,
persis kayak TUI (`htop`, `tmux` status bar, dst).

`read -e` (bash) / `Read-Host` (PS) itu cuma line-editor. Gak punya konsep
"area layar mana yang scroll, mana yang fixed". Gak bisa ditambal, harus ganti
mekanisme inputnya.

## Opsi arsitektur

1. **DECSTBM scroll region** (`\033[<top>;<bottom>r`)
   - Reserve N baris bawah buat prompt, sisanya jadi scroll region buat output.
   - Ringan, no dependency, pure ANSI.
   - Resiko: readline (`read -e`) gak tau ada scroll-region custom → dia bakal
     rebutan kontrol cursor/redraw pas resize atau history-navigate. Support
     beda-beda tiap terminal emulator (xterm-compatible oke, mintty/Windows
     Terminal perlu dicoba langsung, gak bisa gue verifikasi dari sandbox).
   - Kalau read-e diganti raw single-char reader (poin 2), masalah rebutan ini
     hilang — jadi opsi 1 sebenernya prasyarat butuh opsi 2 juga.

2. **Raw keystroke input loop custom** (ganti `read -e` total)
   - Baca char-by-char (`read -rsn1` tiap key), implement sendiri:
     cursor left/right, backspace, history up/down, submit on Enter.
   - Push semua "output" line ke buffer list sendiri, redraw manual: print
     buffer ke scroll-region atas, render prompt line di baris bawah abis itu.
   - Ini yang dipake DECSTBM approach di atas biar gak bentrok sama readline.
   - Effort besar: re-implement arrow-key nav, backspace, history recall,
     tab-completion — semua fitur yang sekarang gratis dari `read -e` harus
     ditulis manual.

3. **Full TUI lib** (contoh: `bashtop`-style manual, atau lompat bahasa ke
   sesuatu yang punya TUI lib beneran — Go+bubbletea, Python+textual/curses,
   Node+ink/blessed)
   - Paling robust, paling gampang maintain long-term.
   - Tapi keluar dari "single bash/ps1 script no-dependency" filosofi project
     ini. Butuh runtime tambahan / build step / distribusi beda dari sekarang
     (install.sh yang ada sekarang cuma taro script + wrapper, gak ada build).

## Rekomendasi

Kalau td tetep mau kejar: opsi 2+1 gabungan (raw input loop + DECSTBM), tetep
pure bash/ps1, konsisten sama arsitektur sekarang. Tapi net effort ≈ nulis
ulang seluruh REPL rendering (bukan nambal `repl()` yang ada).

Kalau prioritas stabilitas & waktu: opsi 3 kalau suatu saat mau upgrade
beneran (proyek terpisah, versi "cpg v2" mungkin), dan biarin REPL sekarang
(boxed per-turn prompt) jadi ceiling buat versi bash/ps1 native.

## Langkah kalau lanjut (opsi 2+1, bash dulu)

1. Buat `_cpg_render()`: given `output_lines[]` array + `input_buffer` string
   + cursor pos int → clear screen area, print `tail -N output_lines` ke
   scroll region atas, print prompt+input_buffer di baris paling bawah,
   posisikan cursor sesuai `cursor_pos`.
2. Set scroll region sekali di awal REPL: `printf '\033[1;%dr' $((rows-2))`
   (reserve 2 baris bawah buat prompt+hint). Restore full-screen scroll
   (`\033[r`) pas keluar REPL / trap EXIT — WAJIB, kalo lupa user punya
   terminal rusak abis keluar.
3. Ganti `read -e -rp` loop jadi `while true; do read -rsn1 key; case
   "$key" in ...) ...; esac; _cpg_render; done` — handle:
   - Enter (`$'\n'`/`$'\r'`) → submit, push ke output, proses command,
     append hasil ke output_lines, clear input_buffer.
   - Backspace (`$'\177'` / `$'\010'`) → pop char at cursor-1.
   - Arrow keys (escape sequences `\033[C`/`\033[D`/`\033[A`/`\033[B`) →
     baca 3-byte escape seq manual, geser cursor / history recall.
   - Ctrl-C (`$'\003'`) → break bersih, restore scroll region.
   - Char biasa → insert at cursor.
4. History array sendiri (bukan bash `history -s` lagi, karena bukan
   readline lagi) — push tiap submit, index buat up/down navigate.
5. Tab-completion: re-pakai logic `_cpg_tab_complete` yang ada, tapi trigger
   manual di key handler (`$'\t'`) langsung manipulasi `input_buffer`.
6. `trap` WINCH: re-set scroll region + reflow tampilan pas resize (gantiin
   WINCH-trap-border yang td didesain — sekarang scope-nya scroll region,
   bukan cuma border ulang).
7. Uji di: Git Bash, WSL, real xterm/Linux kalo ada akses, Windows Terminal.
   HARUS user yang tes tiap langkah — gak bisa diverifikasi dari sandbox gue.
8. PowerShell mirror: `$Host.UI.RawUI` gak punya scroll-region primitive
   native — kemungkinan besar butuh raw `ReadKey()` loop + manual
   `SetCursorPosition` tiap render, dan scroll-region ANSI VT sequences kerja
   di Windows Terminal (VT enabled) tapi TIDAK di conhost lama. Perlu deteksi
   host dulu.
9. Fallback wajib: kalau scroll-region gak kedetect / gagal, otomatis balik
   ke REPL mode sekarang (boxed per-turn) — jangan biarin user stuck di
   layar rusak.

## Status
Belum ada baris kode ditulis buat ini. WINCH-trap-border (fitur lama, lebih
kecil) juga masih pending nempel di `repl()` — itu independen, bisa jalan
duluan/terpisah dari plan ini kalau mau progress kecil dulu.

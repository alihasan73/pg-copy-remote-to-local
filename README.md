README: pg_copy_remote_to_local.sh

File ini menjelaskan tujuan dan cara penggunaan `pg_copy_remote_to_local.sh`.

Tujuan
------
Menyalin database PostgreSQL dari server remote (mis. PostgreSQL 14.x) ke server lokal (mis. PostgreSQL 16.x) secara aman menggunakan dump/restore logis. Skrip menggunakan format directory `pg_dump -Fd` dengan pekerjaan paralel dan `pg_restore` untuk restore paralel.

File yang dibuat
----------------
- `pg_copy_remote_to_local.sh` — skrip utama untuk otomatisasi dump/restore.


Yang dilakukan skrip:
- Membuat direktori dump `./pg_dumps/sourcedb-YYYY-MM-DD`.
- Menjalankan `pg_dump -Fd -j 8` terhadap server remote.
- Mengekspor globals (roles, tablespaces) ke `globals.sql` (tidak otomatis diterapkan kecuali Anda gunakan `--apply-globals`).
- Membuat database target secara lokal dan menjalankan `pg_restore -j 8` ke database tersebut.
- Menjalankan `VACUUM ANALYZE` pada database lokal setelah restore.
- Jika opsi `--verify` diberikan, skrip akan membandingkan jumlah baris tabel di schema `public` antara remote dan lokal dan menyimpan hasilnya ke `verify_counts.csv` di direktori dump.

Catatan penting
--------------
- Skrip tidak menyimpan password; gunakan `REMOTE_PGPASS`/`LOCAL_PGPASS` hanya sementara atau simpan kredensial secara aman di `~/.pgpass` (chmod 600).
- `pg_dump` dan `pg_restore` harus terpasang di mesin yang menjalankan skrip dan kompatibel dengan versi server. Karena skrip menggunakan dump logis, proses antar major version (v14 → v16) umumnya aman.
- Pastikan ekstensi yang diperlukan (mis. `postgis`) sudah terpasang di Postgres lokal sebelum restore. Jika tidak, restore akan gagal untuk objek yang bergantung pada ekstensi.
- Opsi `--apply-globals` dapat membuat role/tablespace di server lokal; selalu tinjau `globals.sql` sebelum menjalankannya.

Troubleshooting (penyelesaian masalah)
-------------------------------------
- Jika restore gagal karena ekstensi tidak ditemukan: pasang ekstensi yang sesuai di Postgres lokal.
- Jika dump terasa lambat atau membebani server: kurangi nilai `-j`, jalankan dump pada server lalu transfer hasilnya (rsync), atau jalankan `pg_dump` dengan `nice`/`ionice` untuk menurunkan prioritas.
- Jika ruang disk terbatas: pertimbangkan streaming dump via SSH atau menggunakan custom-format lalu transfer file terkompresi; catatan: custom format tidak mendukung dump paralel pada sisi server.

Contoh singkat penggunaan
-------------------------
Contoh menjalankan skrip dengan password lewat environment (tidak direkomendasikan untuk script yang tersimpan):

```bash
chmod +x ./scripts/pg_copy_remote_to_local.sh

REMOTE_PGPASS=secret LOCAL_PGPASS=localpass \
  ./scripts/pg_copy_remote_to_local.sh -H 192.168.10.41 -U remoteuser -d sourcedb -u localuser -L targetdb -j 8 --verify --overwrite-dir
```

// bifold-mtp — pomocnik Bifolda do telefonów z Androidem (MTP) na libmtp z Homebrew.
// Czyta foldery pojedynczo (LIBMTP_Get_Files_And_Folders), zamiast całego telefonu naraz jak
// narzędzia mtp-files / mtp-folders — na telefonie z tysiącami zdjęć to różnica minut.
//
//   bifold-mtp detect        lista telefonów (JSON) bez otwierania sesji MTP
//   bifold-mtp serve N [VID PID BUS DEV]
//                            sesja z telefonem N (albo o tym identyfikatorze USB); polecenia na stdin, jedna odpowiedź JSON na wiersz:
//     storages               nośniki (ponownie — telefon udostępnia je dopiero po „Zezwól” na ekranie)
//     list STORAGE PARENT    zawartość folderu (PARENT 4294967295 = korzeń nośnika)
//     get ID ŚCIEŻKA         pobranie pliku do ścieżki lokalnej (reszta wiersza)
//     quit
#include <libmtp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <inttypes.h>
#include <unistd.h>

// Odpowiedzi idą osobnym strumieniem: libmtp pisze komunikaty na stdout, a ten trafia na stderr.
static FILE *out;
static void fputc_out(int c) { fputc(c, out); }

// Długość poprawnej sekwencji UTF-8 zaczynającej się w `p` (0 = niepoprawna).
static int utf8_length(const unsigned char *p) {
    int n = p[0] < 0x80 ? 1 : (p[0] & 0xE0) == 0xC0 ? 2 : (p[0] & 0xF0) == 0xE0 ? 3 : (p[0] & 0xF8) == 0xF0 ? 4 : 0;
    if (n == 0 || (n == 2 && p[0] < 0xC2) || (n == 4 && p[0] > 0xF4)) return 0;
    for (int i = 1; i < n; i++) if ((p[i] & 0xC0) != 0x80) return 0;
    if (n == 3 && ((p[0] == 0xE0 && p[1] < 0xA0) || (p[0] == 0xED && p[1] >= 0xA0))) return 0;
    if (n == 4 && ((p[0] == 0xF0 && p[1] < 0x90) || (p[0] == 0xF4 && p[1] >= 0x90))) return 0;
    return n;
}

// Napis JSON; niepoprawne bajty UTF-8 (nazwy z telefonu) jako U+FFFD — jedna zła nazwa nie może
// zepsuć całej odpowiedzi.
static void json_string(const char *s) {
    fputc_out('"');
    for (const unsigned char *p = (const unsigned char *)(s ? s : ""); *p;) {
        int n = utf8_length(p);
        if (n == 0) { fputs("\\ufffd", out); p++; continue; }
        if (*p == '"' || *p == '\\') fprintf(out, "\\%c", *p);
        else if (*p < 0x20 || *p == 0x7F) fprintf(out, "\\u%04x", *p);
        else fwrite(p, 1, (size_t)n, out);
        p += n;
    }
    fputc_out('"');
}

// Ścieżka docelowa `get`: bez znaków sterujących (polecenia są rozdzielane znakiem nowej linii).
static int safe_path(const char *s) {
    if (!*s) return 0;
    for (const unsigned char *p = (const unsigned char *)s; *p; p++) if (*p < 0x20 || *p == 0x7F) return 0;
    return 1;
}

static void error_reply(LIBMTP_mtpdevice_t *dev, const char *fallback) {
    const char *msg = fallback;
    LIBMTP_error_t *stack = dev ? LIBMTP_Get_Errorstack(dev) : NULL;
    if (stack && stack->error_text) msg = stack->error_text;
    fprintf(out, "{\"ok\":false,\"error\":");
    json_string(msg);
    fprintf(out, "}\n");
    fflush(out);
    if (dev) LIBMTP_Clear_Errorstack(dev);
}

static int detect(void) {
    LIBMTP_raw_device_t *raw = NULL;
    int count = 0;
    LIBMTP_error_number_t err = LIBMTP_Detect_Raw_Devices(&raw, &count);
    fprintf(out, "[");
    if (err == LIBMTP_ERROR_NONE) {
        for (int i = 0; i < count; i++) {
            fprintf(out, "%s{\"index\":%d,\"vendor\":", i ? "," : "", i);
            json_string(raw[i].device_entry.vendor);
            fprintf(out, ",\"product\":");
            json_string(raw[i].device_entry.product);
            fprintf(out, ",\"vid\":%u,\"pid\":%u,\"bus\":%u,\"dev\":%u}", raw[i].device_entry.vendor_id,
                   raw[i].device_entry.product_id, raw[i].bus_location, raw[i].devnum);
        }
    }
    fprintf(out, "]\n");
    free(raw);
    return 0;
}

static void storages(LIBMTP_mtpdevice_t *dev) {
    LIBMTP_Get_Storage(dev, LIBMTP_STORAGE_SORTBY_NOTSORTED);
    LIBMTP_Clear_Errorstack(dev);
    fprintf(out, "[");
    int first = 1;
    for (LIBMTP_devicestorage_t *s = dev->storage; s; s = s->next) {
        fprintf(out, "%s{\"id\":%u,\"name\":", first ? "" : ",", s->id);
        json_string(s->StorageDescription);
        fprintf(out, ",\"total\":%" PRIu64 ",\"free\":%" PRIu64 "}", s->MaxCapacity, s->FreeSpaceInBytes);
        first = 0;
    }
    fprintf(out, "]");
}

// Wybór telefonu: z identyfikatorem USB (`match`) — ten sam vid:pid i bus:dev, a gdy po ponownym
// podłączeniu bus:dev się zmienił — jedyny telefon z tym vid:pid. Inaczej numer z listy `detect`
// (po odłączeniu jednego z dwóch telefonów numer wskazywałby już inny telefon).
static int pick(LIBMTP_raw_device_t *raw, int count, int index, const unsigned *match) {
    if (!match) return index >= 0 && index < count ? index : -1;
    int found = -1, same_model = 0;
    for (int i = 0; i < count; i++) {
        if (raw[i].device_entry.vendor_id != match[0] || raw[i].device_entry.product_id != match[1]) continue;
        if (raw[i].bus_location == match[2] && raw[i].devnum == match[3]) return i;
        found = i;
        same_model++;
    }
    return same_model == 1 ? found : -1;
}

static int serve(int requested, const unsigned *match) {
    LIBMTP_raw_device_t *raw = NULL;
    int count = 0;
    int index = -1;
    if (LIBMTP_Detect_Raw_Devices(&raw, &count) == LIBMTP_ERROR_NONE) index = pick(raw, count, requested, match);
    if (index < 0) {
        free(raw);
        error_reply(NULL, "Nie wykryto telefonu (podłącz go i wybierz tryb Przesyłanie plików)");
        return 1;
    }
    // Bez pamięci podręcznej: zwykłe otwarcie wczytuje od razu cały telefon.
    LIBMTP_mtpdevice_t *dev = LIBMTP_Open_Raw_Device_Uncached(&raw[index]);
    free(raw);
    if (!dev) {
        error_reply(NULL, "Nie udało się otworzyć telefonu — odblokuj go i zezwól na dostęp do danych");
        return 1;
    }
    char *model = LIBMTP_Get_Modelname(dev);
    char *friendly = LIBMTP_Get_Friendlyname(dev);
    fprintf(out, "{\"ok\":true,\"model\":");
    json_string(model);
    fprintf(out, ",\"name\":");
    json_string(friendly);
    fprintf(out, ",\"storages\":");
    storages(dev);
    fprintf(out, "}\n");
    fflush(out);
    free(model);
    free(friendly);

    char line[8192];
    while (fgets(line, sizeof line, stdin)) {
        line[strcspn(line, "\n")] = 0;
        unsigned storage = 0, parent = 0, id = 0;
        int consumed = 0;
        if (strcmp(line, "quit") == 0) break;
        if (strcmp(line, "storages") == 0) {
            fprintf(out, "{\"ok\":true,\"storages\":");
            storages(dev);
            fprintf(out, "}\n");
            fflush(out);
            continue;
        }
        if (sscanf(line, "list %u %u", &storage, &parent) == 2) {
            LIBMTP_file_t *files = LIBMTP_Get_Files_And_Folders(dev, storage, parent);
            LIBMTP_error_t *stack = LIBMTP_Get_Errorstack(dev);
            if (!files && stack) { error_reply(dev, "Nie udało się odczytać folderu"); continue; }
            // Ostrzeżenia z udanego odczytu nie mogą trafić do odpowiedzi na następne polecenie.
            LIBMTP_Clear_Errorstack(dev);
            fprintf(out, "{\"ok\":true,\"items\":[");
            int first = 1;
            for (LIBMTP_file_t *f = files; f;) {
                fprintf(out, "%s{\"id\":%u,\"name\":", first ? "" : ",", f->item_id);
                json_string(f->filename);
                fprintf(out, ",\"size\":%" PRIu64 ",\"mtime\":%ld,\"folder\":%s}", f->filesize, (long)f->modificationdate,
                       f->filetype == LIBMTP_FILETYPE_FOLDER ? "true" : "false");
                first = 0;
                LIBMTP_file_t *next = f->next;
                LIBMTP_destroy_file_t(f);
                f = next;
            }
            fprintf(out, "]}\n");
            fflush(out);
        } else if (sscanf(line, "get %u %n", &id, &consumed) == 1 && consumed > 0) {
            if (!safe_path(line + consumed)) {
                error_reply(NULL, "Nieprawidłowa ścieżka docelowa");
            } else if (LIBMTP_Get_File_To_File(dev, id, line + consumed, NULL, NULL) != 0) {
                error_reply(dev, "Nie udało się pobrać pliku");
            } else {
                fprintf(out, "{\"ok\":true}\n");
                fflush(out);
            }
        } else {
            error_reply(NULL, "Nieznane polecenie");
        }
    }
    LIBMTP_Release_Device(dev);
    return 0;
}

int main(int argc, char **argv) {
    out = fdopen(dup(STDOUT_FILENO), "w");
    dup2(STDERR_FILENO, STDOUT_FILENO);
    LIBMTP_Init();
    if (argc >= 2 && strcmp(argv[1], "detect") == 0) return detect();
    if (argc == 7 && strcmp(argv[1], "serve") == 0) {
        unsigned match[4];
        for (int i = 0; i < 4; i++) match[i] = (unsigned)strtoul(argv[3 + i], NULL, 10);
        return serve(atoi(argv[2]), match);
    }
    if (argc >= 3 && strcmp(argv[1], "serve") == 0) return serve(atoi(argv[2]), NULL);
    fprintf(stderr, "użycie: bifold-mtp detect | serve N [VID PID BUS DEV]\n");
    return 2;
}

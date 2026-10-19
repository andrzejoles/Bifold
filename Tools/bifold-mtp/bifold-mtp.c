// bifold-mtp — pomocnik Bifolda do telefonów z Androidem (MTP) na libmtp z Homebrew.
// Czyta foldery pojedynczo (LIBMTP_Get_Files_And_Folders), zamiast całego telefonu naraz jak
// narzędzia mtp-files / mtp-folders — na telefonie z tysiącami zdjęć to różnica minut.
//
//   bifold-mtp detect        lista telefonów (JSON) bez otwierania sesji MTP
//   bifold-mtp serve N       sesja z telefonem N; polecenia na stdin, jedna odpowiedź JSON na wiersz:
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

static void json_string(const char *s) {
    fputc_out('"');
    for (const unsigned char *p = (const unsigned char *)(s ? s : ""); *p; p++) {
        if (*p == '"' || *p == '\\') fprintf(out, "\\%c", *p);
        else if (*p < 0x20) fprintf(out, "\\u%04x", *p);
        else fputc_out(*p);
    }
    fputc_out('"');
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

static int serve(int index) {
    LIBMTP_raw_device_t *raw = NULL;
    int count = 0;
    if (LIBMTP_Detect_Raw_Devices(&raw, &count) != LIBMTP_ERROR_NONE || index < 0 || index >= count) {
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
            if (LIBMTP_Get_File_To_File(dev, id, line + consumed, NULL, NULL) != 0) {
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
    if (argc >= 3 && strcmp(argv[1], "serve") == 0) return serve(atoi(argv[2]));
    fprintf(stderr, "użycie: bifold-mtp detect | serve N\n");
    return 2;
}

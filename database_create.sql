
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "btree_gist";

-- Kod indeksowy z QR: duże litery, cyfry, myślnik, 3–50 znaków
CREATE DOMAIN d_kod_indeksowy AS VARCHAR(50)
    CHECK (VALUE ~ '^[A-Z0-9\-]{3,50}$');

-- Kwota pieniężna: nieujemna
CREATE DOMAIN d_kwota AS NUMERIC(14, 2)
    CHECK (VALUE >= 0);

CREATE TYPE rola_uzytkownika      AS ENUM ('admin', 'edytor', 'podgląd');
CREATE TYPE akcja_audytu          AS ENUM ('DODANIE', 'ZMIANA', 'USUNIECIE');
CREATE TYPE status_sesji          AS ENUM ('aktywna', 'zakonczona', 'anulowana');
CREATE TYPE status_skanu          AS ENUM (
    'potwierdzone',     -- zeskanowany, sala zgodna z bazą
    'przeniesione',     -- zeskanowany, inna sala niż w bazie
    'brak_skanu',       -- jest w bazie, nie zeskanowany w sesji
    'niezarejestrowane' -- zeskanowany kod którego nie ma w bazie
);


CREATE TABLE kategorie (
    id          SMALLSERIAL  PRIMARY KEY,
    nazwa       VARCHAR(80)  NOT NULL,
    opis        TEXT,
    CONSTRAINT uq_kategorie_nazwa UNIQUE (nazwa)
);
-- Przykładowy rekord:
-- id=1 | nazwa='służba wyszkolenia' | opis=NULL

CREATE TABLE sale (
    id    SERIAL       PRIMARY KEY,
    nazwa VARCHAR(100) NOT NULL,
    CONSTRAINT uq_sale_nazwa UNIQUE (nazwa)
);
-- Przykładowy rekord:
-- id=1 | nazwa='3.050'

CREATE TABLE szafy (
    id      SERIAL      PRIMARY KEY,
    numer   VARCHAR(30) NOT NULL,
    sala_id INT         NOT NULL,
    opis    TEXT,
    CONSTRAINT uq_szafy_numer  UNIQUE (numer),
    CONSTRAINT fk_szafy_sala   FOREIGN KEY (sala_id)
        REFERENCES sale (id) ON DELETE RESTRICT ON UPDATE CASCADE
);
-- Przykładowy rekord:
-- id=1 | numer='SZ-01' | sala_id=1 | opis=NULL

CREATE TABLE uzytkownicy (
    id              SERIAL              PRIMARY KEY,
    nazwa           VARCHAR(100)        NOT NULL  CHECK (length(trim(nazwa)) > 0),
    rola            rola_uzytkownika    NOT NULL  DEFAULT 'podgląd',
    hash_hasla      TEXT,
    aktywny         BOOLEAN             NOT NULL  DEFAULT TRUE,
    ostatnie_login  TIMESTAMPTZ,
    utworzono       TIMESTAMPTZ         NOT NULL  DEFAULT NOW()
);
-- Przykładowy rekord:
-- id=1 | nazwa='Jan Kowalski' | rola='edytor' | aktywny=TRUE

CREATE TABLE przedmioty (
    id              SERIAL          PRIMARY KEY,
    kod_indeksowy   d_kod_indeksowy NOT NULL,
    nazwa           VARCHAR(200)    NOT NULL  CHECK (length(trim(nazwa)) > 0),
    numer_seryjny   VARCHAR(100),
    kategoria_id    SMALLINT,
    wartosc         d_kwota,
    sala_id         INT             NOT NULL,
    w_szafie        BOOLEAN         NOT NULL  DEFAULT FALSE,
    szafa_id        INT,
    aktywny         BOOLEAN         NOT NULL  DEFAULT TRUE,
    uwagi           TEXT,
    utworzono       TIMESTAMPTZ     NOT NULL  DEFAULT NOW(),
    zaktualizowano  TIMESTAMPTZ     NOT NULL  DEFAULT NOW(),

    CONSTRAINT uq_przedmioty_kod        UNIQUE (kod_indeksowy),
    CONSTRAINT fk_przedmioty_sala       FOREIGN KEY (sala_id)
        REFERENCES sale (id) ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_przedmioty_szafa      FOREIGN KEY (szafa_id)
        REFERENCES szafy (id) ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_przedmioty_kategoria  FOREIGN KEY (kategoria_id)
        REFERENCES kategorie (id) ON DELETE SET NULL ON UPDATE CASCADE,
    CONSTRAINT chk_przedmioty_szafa     CHECK (
        (w_szafie = FALSE AND szafa_id IS NULL)
        OR
        (w_szafie = TRUE  AND szafa_id IS NOT NULL)
    )
    -- Zgodność szafy z salą: weryfikuje trigger trg_check_szafa_sala
);
-- Przykładowy rekord:
-- id=1 | kod_indeksowy='IDX-00001' | nazwa='Monitor Dell 24"' | wartosc=1200.00
-- sala_id=2 | w_szafie=FALSE | szafa_id=NULL | aktywny=TRUE

CREATE TABLE dziennik_zmian (
    id          BIGSERIAL       PRIMARY KEY,
    przedmiot_id INT            NOT NULL,
    -- Celowo bez FK CASCADE: historia zostaje po usunięciu przedmiotu
    akcja       akcja_audytu    NOT NULL,
    zmieniono   TIMESTAMPTZ     NOT NULL  DEFAULT NOW(),
    zmienione_przez INT,
    stare_dane  JSONB,          -- NULL przy DODANIU
    nowe_dane   JSONB           NOT NULL,
    CONSTRAINT fk_dziennik_uzytkownik FOREIGN KEY (zmienione_przez)
        REFERENCES uzytkownicy (id) ON DELETE SET NULL
);
-- Przykładowy rekord (wypełniany automatycznie przez trigger):
-- id=1 | przedmiot_id=1 | akcja='DODANIE' | zmieniono=NOW()
-- stare_dane=NULL | nowe_dane={"id":1,"kod_indeksowy":"IDX-00001",...}

CREATE TABLE sesje_inwentaryzacji (
    id              SERIAL          PRIMARY KEY,
    nazwa           VARCHAR(200)    NOT NULL  CHECK (length(trim(nazwa)) > 0),
    opis            TEXT,
    zakres_sala_id  INT,            -- NULL = całe biuro
    status          status_sesji    NOT NULL  DEFAULT 'aktywna',
    rozpoczeto      TIMESTAMPTZ     NOT NULL  DEFAULT NOW(),
    zakończono      TIMESTAMPTZ,
    rozpoczal       INT             NOT NULL,
    zakonczyl       INT,

    CONSTRAINT uq_sesje_nazwa UNIQUE (nazwa),

    CONSTRAINT fk_sesje_sala        FOREIGN KEY (zakres_sala_id)
        REFERENCES sale (id) ON DELETE SET NULL,
    CONSTRAINT fk_sesje_rozpoczal   FOREIGN KEY (rozpoczal)
        REFERENCES uzytkownicy (id) ON DELETE RESTRICT,
    CONSTRAINT fk_sesje_zakonczyl   FOREIGN KEY (zakonczyl)
        REFERENCES uzytkownicy (id) ON DELETE SET NULL,

    CONSTRAINT chk_sesje_zakonczone CHECK (
        (status = 'zakonczona' AND zakończono IS NOT NULL AND zakonczyl IS NOT NULL)
        OR status <> 'zakonczona'
    ),
    CONSTRAINT chk_sesje_daty CHECK (
        zakończono IS NULL OR zakończono >= rozpoczeto
    )
);

-- Tylko jedna aktywna sesja jednocześnie
CREATE UNIQUE INDEX uidx_jedna_aktywna_sesja
    ON sesje_inwentaryzacji (status)
    WHERE status = 'aktywna';

-- Przykładowy rekord:
-- id=1 | nazwa='Inwentaryzacja Q1 2025' | zakres_sala_id=NULL
-- status='aktywna' | rozpoczeto=NOW() | rozpoczal=1

CREATE TABLE skany_inwentaryzacji (
    id                  BIGSERIAL           PRIMARY KEY,
    sesja_id            INT                 NOT NULL,
    przedmiot_id        INT,                -- NULL gdy niezarejestrowane
    zeskanowany_kod     d_kod_indeksowy     NOT NULL,
    zeskanowana_sala_id INT,
    status_skanu        status_skanu,       -- NULL przed finalizacją
    zeskanowano         TIMESTAMPTZ         NOT NULL  DEFAULT NOW(),
    zeskanowal          INT                 NOT NULL,
    roznica             TEXT,

    CONSTRAINT uq_skan_sesja_kod UNIQUE (sesja_id, zeskanowany_kod),

    CONSTRAINT fk_skan_sesja        FOREIGN KEY (sesja_id)
        REFERENCES sesje_inwentaryzacji (id) ON DELETE CASCADE,
    CONSTRAINT fk_skan_przedmiot    FOREIGN KEY (przedmiot_id)
        REFERENCES przedmioty (id) ON DELETE SET NULL,
    CONSTRAINT fk_skan_sala         FOREIGN KEY (zeskanowana_sala_id)
        REFERENCES sale (id) ON DELETE SET NULL,
    CONSTRAINT fk_skan_uzytkownik   FOREIGN KEY (zeskanowal)
        REFERENCES uzytkownicy (id) ON DELETE RESTRICT
);
-- Przykładowy rekord (wstawiany przez apkę w trakcie skanowania):
-- id=1 | sesja_id=1 | przedmiot_id=1 | zeskanowany_kod='IDX-00001'
-- zeskanowana_sala_id=2 | status_skanu=NULL | zeskanowal=2


CREATE OR REPLACE FUNCTION fn_set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    NEW.zaktualizowano := NOW();
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_przedmioty_updated_at
    BEFORE UPDATE ON przedmioty
    FOR EACH ROW
    EXECUTE FUNCTION fn_set_updated_at();


CREATE OR REPLACE FUNCTION fn_items_audit()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO dziennik_zmian (przedmiot_id, akcja, nowe_dane)
        VALUES (NEW.id, 'DODANIE', to_jsonb(NEW));

    ELSIF TG_OP = 'UPDATE' THEN
        IF NEW IS DISTINCT FROM OLD THEN
            INSERT INTO dziennik_zmian (przedmiot_id, akcja, stare_dane, nowe_dane)
            VALUES (NEW.id, 'ZMIANA', to_jsonb(OLD), to_jsonb(NEW));
        END IF;

    ELSIF TG_OP = 'DELETE' THEN
        INSERT INTO dziennik_zmian (przedmiot_id, akcja, stare_dane, nowe_dane)
        VALUES (OLD.id, 'USUNIECIE', to_jsonb(OLD), to_jsonb(OLD));
    END IF;

    RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE TRIGGER trg_items_audit
    AFTER INSERT OR UPDATE OR DELETE ON przedmioty
    FOR EACH ROW
    EXECUTE FUNCTION fn_items_audit();


CREATE OR REPLACE FUNCTION fn_check_cabinet_room()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_sala_id_szafy INT;
BEGIN
    IF NEW.szafa_id IS NOT NULL THEN
        SELECT sala_id INTO v_sala_id_szafy
        FROM szafy WHERE id = NEW.szafa_id;

        IF v_sala_id_szafy <> NEW.sala_id THEN
            RAISE EXCEPTION
                'Szafa % należy do sali %, a przedmiot wskazuje salę %.',
                NEW.szafa_id, v_sala_id_szafy, NEW.sala_id
                USING ERRCODE = 'integrity_constraint_violation';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_check_szafa_sala
    BEFORE INSERT OR UPDATE OF sala_id, szafa_id ON przedmioty
    FOR EACH ROW
    EXECUTE FUNCTION fn_check_cabinet_room();

CREATE OR REPLACE FUNCTION finalize_inventory_session(
    p_sesja_id  INT,
    p_user_id   INT
)
RETURNS TABLE (status_skanu status_skanu, liczba BIGINT)
LANGUAGE plpgsql AS $$
DECLARE
    v_zakres_sala_id INT;
BEGIN
    SELECT zakres_sala_id INTO v_zakres_sala_id
    FROM sesje_inwentaryzacji
    WHERE id = p_sesja_id AND status = 'aktywna';

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Sesja % nie istnieje lub nie jest aktywna.', p_sesja_id;
    END IF;

    -- potwierdzone: sala zgodna
    UPDATE skany_inwentaryzacji s
    SET status_skanu = 'potwierdzone',
        roznica      = NULL
    FROM przedmioty p
    WHERE s.sesja_id            = p_sesja_id
      AND s.przedmiot_id        = p.id
      AND s.status_skanu        IS NULL
      AND s.zeskanowana_sala_id = p.sala_id;

    -- przeniesione: inna sala
    UPDATE skany_inwentaryzacji s
    SET status_skanu = 'przeniesione',
        roznica      = format(
            'Baza: sala=%s | Skan: sala=%s',
            p.sala_id, s.zeskanowana_sala_id
        )
    FROM przedmioty p
    WHERE s.sesja_id     = p_sesja_id
      AND s.przedmiot_id = p.id
      AND s.status_skanu IS NULL;

    -- niezarejestrowane: kod z QR nieznany
    UPDATE skany_inwentaryzacji
    SET status_skanu = 'niezarejestrowane',
        roznica      = 'Kod QR nie istnieje w bazie — możliwy nowy przedmiot.'
    WHERE sesja_id    = p_sesja_id
      AND przedmiot_id IS NULL
      AND status_skanu IS NULL;

    -- brak_skanu: przedmioty z bazy niezeskanowane
    INSERT INTO skany_inwentaryzacji
        (sesja_id, przedmiot_id, zeskanowany_kod,
         zeskanowano, zeskanowal, status_skanu, roznica)
    SELECT
        p_sesja_id, p.id, p.kod_indeksowy,
        NOW(), p_user_id,
        'brak_skanu', 'Przedmiot nie został zeskanowany.'
    FROM przedmioty p
    WHERE p.aktywny = TRUE
      AND (v_zakres_sala_id IS NULL OR p.sala_id = v_zakres_sala_id)
      AND NOT EXISTS (
          SELECT 1 FROM skany_inwentaryzacji s
          WHERE s.sesja_id = p_sesja_id AND s.przedmiot_id = p.id
      );

    -- Zamknij sesję
    UPDATE sesje_inwentaryzacji
    SET status      = 'zakonczona',
        zakończono  = NOW(),
        zakonczyl   = p_user_id
    WHERE id = p_sesja_id;

    -- Podsumowanie
    RETURN QUERY
    SELECT s.status_skanu, COUNT(*)
    FROM skany_inwentaryzacji s
    WHERE s.sesja_id = p_sesja_id
    GROUP BY s.status_skanu
    ORDER BY s.status_skanu;
END;
$$;


--  Indeksy

CREATE INDEX idx_przedmioty_sala       ON przedmioty (sala_id);
CREATE INDEX idx_przedmioty_szafa      ON przedmioty (szafa_id);
CREATE INDEX idx_przedmioty_kategoria  ON przedmioty (kategoria_id);
CREATE INDEX idx_przedmioty_aktywne    ON przedmioty (id) WHERE aktywny = TRUE;

CREATE INDEX idx_dziennik_przedmiot    ON dziennik_zmian (przedmiot_id);
CREATE INDEX idx_dziennik_czas         ON dziennik_zmian USING BRIN (zmieniono);

CREATE INDEX idx_skany_sesja           ON skany_inwentaryzacji (sesja_id);
CREATE INDEX idx_skany_przedmiot       ON skany_inwentaryzacji (przedmiot_id);
CREATE INDEX idx_skany_status          ON skany_inwentaryzacji (sesja_id, status_skanu);

-- Widoki
CREATE VIEW v_przedmioty_pelne AS
SELECT
    p.id,
    p.kod_indeksowy,
    p.nazwa,
    p.numer_seryjny,
    k.nazwa         AS kategoria,
    p.wartosc,
    s.nazwa         AS sala,
    p.w_szafie,
    sz.numer        AS szafa,
    p.uwagi,
    p.utworzono,
    p.zaktualizowano
FROM przedmioty p
JOIN  sale       s  ON s.id  = p.sala_id
LEFT JOIN szafy  sz ON sz.id = p.szafa_id
LEFT JOIN kategorie k ON k.id = p.kategoria_id
WHERE p.aktywny = TRUE;

-- Raport z sesji inwentaryzacji: SELECT * FROM v_raport_inwentaryzacji WHERE sesja_id = 1 AND status_skanu <> 'potwierdzone';
CREATE VIEW v_raport_inwentaryzacji AS
SELECT
    si.sesja_id,
    ses.nazwa           AS nazwa_sesji,
    si.zeskanowany_kod,
    p.nazwa             AS nazwa_w_bazie,
    p.wartosc           AS wartosc_w_bazie,
    s_db.nazwa          AS sala_w_bazie,
    s_sc.nazwa          AS sala_zeskanowana,
    si.status_skanu,
    si.roznica,
    si.zeskanowano,
    u.nazwa             AS zeskanowal
FROM skany_inwentaryzacji si
JOIN  sesje_inwentaryzacji ses ON ses.id  = si.sesja_id
LEFT JOIN przedmioty       p   ON p.id   = si.przedmiot_id
LEFT JOIN sale             s_db ON s_db.id = p.sala_id
LEFT JOIN sale             s_sc ON s_sc.id = si.zeskanowana_sala_id
LEFT JOIN uzytkownicy      u   ON u.id   = si.zeskanowal;

-- Dane wstępne dla przykładu
-- Kategorie
INSERT INTO kategorie (nazwa) VALUES
    ('służba wyszkolenia'),
    ('służba wychowawcza'),
    ('służba żywnościowa'),
    ('służba łączności'),
    ('służba infrastruktury'),
    ('środki trwałe');

-- Sale
INSERT INTO sale (nazwa) VALUES
    ('0.012'),
    ('3.050'),
    ('3.051'),
    ('3.052'),
    ('3.061'),
    ('3.064'),
    ('3.065'),
    ('3.066'),
    ('4.042'),
    ('4.043'),
    ('4.047'),
    ('4.048'),
    ('4.049');

-- Szafy
INSERT INTO szafy (numer, sala_id) VALUES
    ('SZ-01', 1),
    ('SZ-02', 2),
    ('SZ-03', 3),
    ('SZ-04', 4),
    ('SZ-05', 9),
    ('REG-01', 5),
    ('REG-02', 10);

-- Użytkownicy
INSERT INTO uzytkownicy (nazwa, rola) VALUES
    ('Administrator',  'admin'),
    ('Jan Kowalski',   'edytor'),
    ('Anna Nowak',     'podgląd');


-- SŁUŻBA WYSZKOLENIA (kategoria_id=1) 
INSERT INTO przedmioty (kod_indeksowy, nazwa, wartosc, kategoria_id, sala_id, w_szafie, szafa_id) VALUES
('IDX-00001', 'Monitor Dell 24" Full HD',            1200.00, 1, 2, FALSE, NULL),
('IDX-00002', 'Monitor LG 27" IPS',                  1450.00, 1, 2, FALSE, NULL),
('IDX-00003', 'Monitor Samsung 22" HD',               890.00, 1, 3, FALSE, NULL),
('IDX-00004', 'Ekran projekcyjny 200x200cm',          650.00, 1, 5, FALSE, NULL),
('IDX-00005', 'Ekran projekcyjny 120x120cm rolowany', 380.00, 1, 6, FALSE, NULL),
('IDX-00006', 'Rzutnik Epson EB-S41',                2100.00, 1, 2, FALSE, NULL),
('IDX-00007', 'Rzutnik BenQ MH535',                  2400.00, 1, 3, FALSE, NULL),
('IDX-00008', 'Rzutnik Optoma HD28HDR',              2800.00, 1, 5, FALSE, NULL),
('IDX-00009', 'Multimetr cyfrowy UNI-T UT61E',        320.00, 1, 2, TRUE,  2),
('IDX-00010', 'Multimetr analogowy AXIOMET AX-9',     180.00, 1, 2, TRUE,  2),
('IDX-00011', 'Multimetr Fluke 115',                  750.00, 1, 3, TRUE,  3),
('IDX-00012', 'Rezystor 1kΩ 1W (komplet 50szt)',       45.00, 1, 2, TRUE,  2),
('IDX-00013', 'Rezystor 10kΩ 0.5W (komplet 50szt)',    40.00, 1, 2, TRUE,  2),
('IDX-00014', 'Zasilacz laboratoryjny 30V 5A',        480.00, 1, 3, TRUE,  3),
('IDX-00015', 'Lutownica stacyjna Hakko FX-888D',     420.00, 1, 3, TRUE,  3),
('IDX-00016', 'Tablica szkolna suchościeralna 180cm', 550.00, 1, 5, FALSE, NULL),
('IDX-00017', 'Flipchart magnetyczny z papierem',     340.00, 1, 6, FALSE, NULL),
('IDX-00018', 'Wskaźnik laserowy zielony',             95.00, 1, 2, TRUE,  2),

-- SŁUŻBA WYCHOWAWCZA (kategoria_id=2)
('IDX-00019', 'Flaga państwowa 150x90cm',             120.00, 2, 4, FALSE, NULL),
('IDX-00020', 'Flaga jednostki 150x90cm',             140.00, 2, 4, FALSE, NULL),
('IDX-00021', 'Flaga okolicznościowa 100x60cm',        80.00, 2, 4, TRUE,  4),
('IDX-00022', 'Stojak na flagę — podstawa metalowa',  210.00, 2, 4, FALSE, NULL),
('IDX-00023', 'Stojak na odzież — wieszak stojący',   180.00, 2, 8, FALSE, NULL),
('IDX-00024', 'Stojak na odzież — wieszak ścienny',   120.00, 2, 7, FALSE, NULL),
('IDX-00025', 'Gilotyna do papieru A4 Dahle 550',     390.00, 2, 4, TRUE,  4),
('IDX-00026', 'Gilotyna do papieru A3 Fellowes',      520.00, 2, 8, FALSE, NULL),
('IDX-00027', 'Ulotki informacyjne (ryza 500szt)',      35.00, 2, 4, TRUE,  4),
('IDX-00028', 'Ulotki rekrutacyjne (ryza 500szt)',      35.00, 2, 4, TRUE,  4),
('IDX-00029', 'Plansza informacyjna A1 laminowana',    65.00, 2, 7, FALSE, NULL),
('IDX-00030', 'Ramka ekspozycyjna A1 stojąca',        150.00, 2, 8, FALSE, NULL),
('IDX-00031', 'Segregator prezentacyjny A4 30-kieszeniowy', 25.00, 2, 4, TRUE, 4),
('IDX-00032', 'Tablica korkowa 120x90cm z ramą',      180.00, 2, 7, FALSE, NULL),

-- SŁUŻBA ŻYWNOŚCIOWA (kategoria_id=3) 
('IDX-00033', 'Ekspres do kawy DeLonghi ECAM 22.110', 980.00, 3, 1, FALSE, NULL),
('IDX-00034', 'Ekspres przelewowy Philips HD7546',    320.00, 3, 9, FALSE, NULL),
('IDX-00035', 'Ekspres kapsułkowy Nespresso Essenza', 450.00, 3, 10, FALSE, NULL),
('IDX-00036', 'Czajnik elektryczny Bosch TWK3A011',   150.00, 3, 1,  FALSE, NULL),
('IDX-00037', 'Czajnik elektryczny Philips HD9350',   180.00, 3, 9,  FALSE, NULL),
('IDX-00038', 'Czajnik elektryczny Tefal KI170D',     160.00, 3, 10, FALSE, NULL),
('IDX-00039', 'Filiżanka ceramiczna 200ml (komplet 6szt)', 75.00, 3, 1, TRUE, 1),
('IDX-00040', 'Filiżanka porcelanowa 150ml (komplet 12szt)', 120.00, 3, 9, TRUE, 5),
('IDX-00041', 'Talerz płaski 26cm (komplet 12szt)',   145.00, 3, 9,  TRUE, 5),
('IDX-00042', 'Talerz głęboki 22cm (komplet 12szt)',  145.00, 3, 9,  TRUE, 5),
('IDX-00043', 'Talerz deserowy 18cm (komplet 6szt)',   70.00, 3, 9,  TRUE, 5),
('IDX-00044', 'Termos obiadowy 10L nierdzewny',       280.00, 3, 1,  FALSE, NULL),
('IDX-00045', 'Podgrzewacz do potraw elektryczny',    350.00, 3, 1,  FALSE, NULL),
('IDX-00046', 'Dystrybutor wody stojący Primo',       890.00, 3, 10, FALSE, NULL),
('IDX-00047', 'Lodówka bar 60L Bosch KTR15NWFA',     750.00, 3, 1,  FALSE, NULL),
('IDX-00048', 'Mikrofalówka Panasonic NN-E28JM',      380.00, 3, 1,  FALSE, NULL),

-- SŁUŻBA ŁĄCZNOŚCI (kategoria_id=4) 
('IDX-00049', 'Komputer stacjonarny HP ProDesk 400 G7',  2800.00, 4, 11, FALSE, NULL),
('IDX-00050', 'Komputer stacjonarny Lenovo ThinkCentre', 2600.00, 4, 11, FALSE, NULL),
('IDX-00051', 'Monitor HP P24h G4 24"',               1100.00, 4, 11, FALSE, NULL),
('IDX-00052', 'Monitor LG 24MK430H 24"',              950.00,  4, 11, FALSE, NULL),
('IDX-00053', 'Mysz bezprzewodowa Logitech M185',       65.00, 4, 11, FALSE, NULL),
('IDX-00054', 'Mysz przewodowa HP 150',                 40.00, 4, 11, FALSE, NULL),
('IDX-00055', 'Klawiatura Logitech K120',               75.00, 4, 11, FALSE, NULL),
('IDX-00056', 'Klawiatura mechaniczna Logitech MK850',  220.00, 4, 11, FALSE, NULL),
('IDX-00057', 'Kabel RJ45 kat.6 3m (komplet 10szt)',    85.00, 4, 11, FALSE, NULL),
('IDX-00058', 'Kabel RJ45 kat.6 10m (komplet 5szt)',    75.00, 4, 12, FALSE, NULL),
('IDX-00059', 'Kabel RJ45 kat.6 1m (komplet 20szt)',    90.00, 4, 12, FALSE, NULL),
('IDX-00060', 'Telefon stacjonarny Panasonic KX-TS500', 180.00, 4, 11, FALSE, NULL),
('IDX-00061', 'Telefon stacjonarny Gigaset AS690',      220.00, 4, 12, FALSE, NULL),
('IDX-00062', 'Switch TP-Link TL-SG1024 24-port',       650.00, 4, 11, FALSE, NULL),

-- SŁUŻBA INFRASTRUKTURY (kategoria_id=5) 
('IDX-00063', 'Stół konferencyjny 200x80cm',          1200.00, 5, 5, FALSE, NULL),
('IDX-00064', 'Stół biurowy 160x80cm',                 850.00, 5, 6, FALSE, NULL),
('IDX-00065', 'Stół biurowy narożny 180x140cm',       1100.00, 5, 7, FALSE, NULL),
('IDX-00066', 'Stół składany 180x74cm',                480.00, 5, 8, FALSE, NULL),
('IDX-00067', 'Biurko z szufladami 140x70cm',          950.00, 5, 9, FALSE, NULL),
('IDX-00068', 'Biurko komputerowe 120x60cm',           720.00, 5, 10, FALSE, NULL),
('IDX-00069', 'Krzesło biurowe obrotowe Ergohuman',    890.00, 5, 9,  FALSE, NULL),
('IDX-00070', 'Krzesło konferencyjne tapicerowane',    420.00, 5, 5,  FALSE, NULL),
('IDX-00071', 'Krzesło plastikowe składane',           120.00, 5, 8,  FALSE, NULL),
('IDX-00072', 'Krzesło plastikowe składane',           120.00, 5, 8,  FALSE, NULL),
('IDX-00073', 'Szafa ubraniowa stalowa 2-drzwiowa',    780.00, 5, 13, FALSE, NULL),
('IDX-00074', 'Szafa aktowa metalowa z zamkiem',       650.00, 5, 13, FALSE, NULL),
('IDX-00075', 'Szafa biurowa drewniana 3-półkowa',     520.00, 5, 12, FALSE, NULL),
('IDX-00076', 'Regał metalowy 5-półkowy 180cm',        380.00, 5, 13, FALSE, NULL),
('IDX-00077', 'Kosz na śmieci metalowy 30L',            55.00, 5, 5,  FALSE, NULL),
('IDX-00078', 'Kosz na śmieci plastikowy 20L',          35.00, 5, 6,  FALSE, NULL),
('IDX-00079', 'Kosz segregacja — papier 40L',           65.00, 5, 7,  FALSE, NULL),
('IDX-00080', 'Kosz segregacja — plastik 40L',          65.00, 5, 8,  FALSE, NULL),

-- ŚRODKI TRWAŁE (kategoria_id=6) —
('IDX-00081', 'Komputer AIO HP 200 G4 22" i5',        3200.00, 6, 2,  FALSE, NULL),
('IDX-00082', 'Komputer AIO Lenovo IdeaCentre 24"',   3600.00, 6, 3,  FALSE, NULL),
('IDX-00083', 'Komputer AIO Dell Inspiron 27" i7',    4800.00, 6, 5,  FALSE, NULL),
('IDX-00084', 'Komputer AIO Acer Aspire C24',         3100.00, 6, 6,  FALSE, NULL),
('IDX-00085', 'Laptop HP ProBook 450 G8 i5',          3800.00, 6, 2,  FALSE, NULL),
('IDX-00086', 'Laptop Dell Latitude 5420 i5',         4200.00, 6, 3,  FALSE, NULL),
('IDX-00087', 'Laptop Lenovo ThinkPad E15 i7',        5100.00, 6, 9,  FALSE, NULL),
('IDX-00088', 'Laptop Dell XPS 15 i7',                6200.00, 6, 10, FALSE, NULL),
('IDX-00089', 'Laptop Lenovo ThinkPad X1 Carbon',     7400.00, 6, 11, FALSE, NULL),
('IDX-00090', 'Oscyloskop Rigol DS1054Z 50MHz',       2100.00, 6, 3,  TRUE,  3),
('IDX-00091', 'Oscyloskop Siglent SDS1202X-E 200MHz', 3400.00, 6, 3,  TRUE,  3),
('IDX-00092', 'Oscyloskop Tektronix TBS1072C 70MHz',  2800.00, 6, 2,  TRUE,  2),
('IDX-00093', 'Szafa rack 19" 12U stojąca',           1800.00, 6, 11, FALSE, NULL),
('IDX-00094', 'Szafa rack 19" 24U stojąca',           2900.00, 6, 11, FALSE, NULL),
('IDX-00095', 'Szafa rack 19" 42U stojąca z wentylacją', 5400.00, 6, 11, FALSE, NULL),
('IDX-00096', 'Serwer Dell PowerEdge R340',          12000.00, 6, 11, FALSE, NULL),
('IDX-00097', 'Serwer HP ProLiant DL360 Gen10',      18500.00, 6, 11, FALSE, NULL),
('IDX-00098', 'Serwer Lenovo ThinkSystem SR530',     15200.00, 6, 11, FALSE, NULL),
('IDX-00099', 'UPS APC Smart-UPS 1500VA',             2100.00, 6, 11, FALSE, NULL),
('IDX-00100', 'UPS Eaton 5E 2000VA',                  1400.00, 6, 11, FALSE, NULL);


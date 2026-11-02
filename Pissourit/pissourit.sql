-- Pissourit : schéma SQL PostgreSQL / Supabase
-- Utilise auth.users(id) pour les utilisateurs Communicer.

CREATE TABLE IF NOT EXISTS pissourit_stages (
  id SMALLINT PRIMARY KEY,
  nom TEXT NOT NULL,
  duree_jours INT NOT NULL,
  temp_ideale NUMERIC(4,1) NOT NULL,
  temp_min NUMERIC(4,1) NOT NULL,
  temp_max NUMERIC(4,1) NOT NULL,
  habitat TEXT NOT NULL,
  fertile BOOLEAN NOT NULL DEFAULT FALSE
);

INSERT INTO pissourit_stages VALUES
(0,'Oeuf',4,22,19,25,'etang',FALSE),
(1,'Tetard',3,23,20,26,'etang',FALSE),
(2,'Tetard a pattes',7,22,19,25,'etang',FALSE),
(3,'Larve',14,21,17,25,'jardin',FALSE),
(4,'Chenille',21,22,18,26,'jardin',FALSE),
(5,'Chrysalide',3,21,19,23,'couveuse',FALSE),
(6,'Bebe',21,24,21,27,'nid',FALSE),
(7,'Adolescent',21,23,19,27,'nid',TRUE),
(8,'Jeune-adulte',56,22,17,28,'grand_jardin',TRUE),
(9,'Adulte',119,22,16,29,'grand_jardin',TRUE),
(10,'Vieillot',14,23,20,26,'grand_jardin',FALSE),
(11,'Grand-parent',42,24,21,26,'grand_jardin',FALSE)
ON CONFLICT DO NOTHING;

CREATE TABLE IF NOT EXISTS pissourits (
  id BIGSERIAL PRIMARY KEY,
  nom TEXT,
  sexe CHAR(1) NOT NULL CHECK (sexe IN ('M','F')),
  naissance TIMESTAMPTZ NOT NULL DEFAULT now(),
  stade_suspendu BOOLEAN NOT NULL DEFAULT FALSE,
  mort_le TIMESTAMPTZ,
  pere_id BIGINT REFERENCES pissourits(id),
  mere_id BIGINT REFERENCES pissourits(id),
  seed BIGINT NOT NULL,
  plumes SMALLINT NOT NULL,
  cheveux SMALLINT NOT NULL,
  yeux SMALLINT NOT NULL,
  bec SMALLINT NOT NULL,
  ongles SMALLINT NOT NULL,
  motif TEXT NOT NULL CHECK (motif IN ('uni','tachete','raye')),
  coiffure SMALLINT NOT NULL,
  personnalite TEXT NOT NULL,
  taille TEXT NOT NULL CHECK (taille IN ('petite','moyenne','grande')),
  temperament TEXT NOT NULL,
  rarete TEXT NOT NULL DEFAULT 'commune'
    CHECK (rarete IN ('commune','rare','epique','legendaire')),
  mutation BOOLEAN NOT NULL DEFAULT FALSE,
  corps TEXT NOT NULL DEFAULT 'normal',
  force_ SMALLINT NOT NULL DEFAULT 0,
  endurance_combat SMALLINT NOT NULL DEFAULT 0,
  defense SMALLINT NOT NULL DEFAULT 0,
  consanguin BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE TABLE IF NOT EXISTS pissourit_owners (
  pissourit_id BIGINT REFERENCES pissourits(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  part SMALLINT NOT NULL DEFAULT 100 CHECK (part IN (50,100)),
  PRIMARY KEY (pissourit_id, user_id)
);

CREATE TABLE IF NOT EXISTS pissourit_state (
  pissourit_id BIGINT PRIMARY KEY REFERENCES pissourits(id) ON DELETE CASCADE,
  faim REAL NOT NULL DEFAULT 80,
  soif REAL NOT NULL DEFAULT 80,
  divertissement REAL NOT NULL DEFAULT 80,
  proprete REAL NOT NULL DEFAULT 90,
  energie REAL NOT NULL DEFAULT 90,
  affection REAL NOT NULL DEFAULT 80,
  confort REAL NOT NULL DEFAULT 80,
  sante REAL NOT NULL DEFAULT 100,
  qualite_eau REAL NOT NULL DEFAULT 100,
  endormi BOOLEAN NOT NULL DEFAULT FALSE,
  anesthesie_fin TIMESTAMPTZ,
  derniere_maj TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS pissourit_addiction (
  pissourit_id BIGINT PRIMARY KEY REFERENCES pissourits(id) ON DELETE CASCADE,
  paranoia REAL NOT NULL DEFAULT 0,
  depression REAL NOT NULL DEFAULT 0,
  endurance REAL NOT NULL DEFAULT 0 CHECK (endurance <= 90),
  toxicite REAL NOT NULL DEFAULT 0,
  fertilite REAL NOT NULL DEFAULT 100,
  hydratation REAL NOT NULL DEFAULT 100,
  traumatise BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE TABLE IF NOT EXISTS pissourit_ajout_dependance (
  pissourit_id BIGINT REFERENCES pissourits(id) ON DELETE CASCADE,
  ajout_id BIGINT NOT NULL,
  dependance REAL NOT NULL DEFAULT 0 CHECK (dependance BETWEEN 0 AND 10),
  manque REAL NOT NULL DEFAULT 0 CHECK (manque BETWEEN 0 AND 100),
  PRIMARY KEY (pissourit_id, ajout_id)
);

CREATE TABLE IF NOT EXISTS pissourit_actions (
  id BIGSERIAL PRIMARY KEY,
  pissourit_id BIGINT NOT NULL REFERENCES pissourits(id) ON DELETE CASCADE,
  user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  type TEXT NOT NULL,
  details JSONB,
  cree_le TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_pissourit_actions
ON pissourit_actions(pissourit_id, cree_le DESC);

CREATE TABLE IF NOT EXISTS pissourit_alliances (
  id BIGSERIAL PRIMARY KEY,
  proposant_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  cible_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  pissourit_a BIGINT NOT NULL REFERENCES pissourits(id),
  pissourit_b BIGINT NOT NULL REFERENCES pissourits(id),
  statut TEXT NOT NULL DEFAULT 'en_attente'
    CHECK (statut IN ('en_attente','acceptee','refusee')),
  derniere_naissance TIMESTAMPTZ,
  cree_le TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS pissourit_habitats (
  id BIGSERIAL PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  nom TEXT NOT NULL,
  type TEXT NOT NULL CHECK (type IN ('etang','jardin','couveuse','nid','grand_jardin')),
  temperature NUMERIC(4,1) NOT NULL DEFAULT 22,
  proprete REAL NOT NULL DEFAULT 100,
  visibilite TEXT NOT NULL DEFAULT 'prive'
    CHECK (visibilite IN ('prive','amis','public')),
  layout JSONB
);

ALTER TABLE pissourits
ADD COLUMN IF NOT EXISTS habitat_id BIGINT REFERENCES pissourit_habitats(id);

CREATE TABLE IF NOT EXISTS pissourit_wallet (
  user_id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  jetons BIGINT NOT NULL DEFAULT 20 CHECK (jetons >= 0),
  xp BIGINT NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS pissourit_items (
  id SERIAL PRIMARY KEY,
  categorie TEXT NOT NULL,
  nom TEXT NOT NULL,
  qualite SMALLINT NOT NULL DEFAULT 1,
  prix INT NOT NULL,
  consommable BOOLEAN NOT NULL DEFAULT FALSE,
  transferable BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE IF NOT EXISTS pissourit_inventory (
  user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE,
  item_id INT REFERENCES pissourit_items(id),
  quantite INT NOT NULL DEFAULT 1,
  PRIMARY KEY (user_id,item_id)
);

CREATE TABLE IF NOT EXISTS pissourit_molecules (
  id SERIAL PRIMARY KEY,
  famille TEXT NOT NULL,
  niveau SMALLINT NOT NULL CHECK (niveau BETWEEN 1 AND 6),
  nom TEXT GENERATED ALWAYS AS (famille || ' ' || niveau) STORED,
  intensite SMALLINT GENERATED ALWAYS AS (niveau) STORED,
  effet TEXT NOT NULL,
  type TEXT NOT NULL CHECK (type IN ('avantage','desavantage','visuel')),
  UNIQUE (famille, niveau)
);

INSERT INTO pissourit_molecules (famille, niveau, effet, type)
SELECT f.nom, n, f.effet, f.type
FROM (VALUES
 ('Chromethine','melange de lettres','visuel'),
 ('Deformine','distorsion du site','visuel'),
 ('Motilithe','souris ralentie','visuel'),
 ('Laterine','clics retardes','visuel'),
 ('Temporine','animations ralenties','visuel'),
 ('Animethine','animations hallucinatoires','visuel'),
 ('Obscurine','faux objets','visuel'),
 ('Fantomine','faux Pissourits','visuel'),
 ('Besterite','faux animaux','visuel'),
 ('Optéline','illusions optiques','visuel'),
 ('Paraxine','paranoia','desavantage'),
 ('Fertilithe','fertilite','desavantage'),
 ('Hydraterite','deshydratation','desavantage'),
 ('Vitaline','baisse de sante','desavantage'),
 ('Dependrite','dependance','desavantage'),
 ('Manquelite','manque','desavantage'),
 ('Toxerite','toxicite / overdose','desavantage'),
 ('Endurite','endurance','avantage'),
 ('Nutrilithe','reduction de la faim','avantage'),
 ('Recreolite','divertissement et humeur','avantage')
) AS f(nom,effet,type)
CROSS JOIN generate_series(1,6) AS n
ON CONFLICT DO NOTHING;

CREATE TABLE IF NOT EXISTS pissourit_ajouts (
  id BIGSERIAL PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  nom TEXT NOT NULL,
  molecules JSONB NOT NULL,
  force_ INT NOT NULL DEFAULT 0 CHECK (force_ BETWEEN 0 AND 2000),
  dependance REAL NOT NULL DEFAULT 0 CHECK (dependance BETWEEN 0 AND 10),
  interactions JSONB
);

CREATE TABLE IF NOT EXISTS pissourit_decouvertes (
  user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE,
  cle TEXT NOT NULL,
  details JSONB,
  trouve_le TIMESTAMPTZ DEFAULT now(),
  PRIMARY KEY (user_id, cle)
);

CREATE TABLE IF NOT EXISTS pissourit_nicotine_niveaux (
  mg_ml INT PRIMARY KEY,
  legal BOOLEAN NOT NULL DEFAULT TRUE
);

INSERT INTO pissourit_nicotine_niveaux (mg_ml)
VALUES (1),(2),(5),(10),(15),(25),(30),(45),(65),(90),(120),(150),(200),(300),(450),(600),(820),(1125)
ON CONFLICT DO NOTHING;

CREATE TABLE IF NOT EXISTS pissourit_vapes (
  id BIGSERIAL PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  type TEXT NOT NULL DEFAULT 'vape' CHECK (type IN ('vape','cigare','cigarette')),
  ressort_id INT,
  systeme_id INT,
  chaufferette_id INT,
  corps_id INT,
  colle_id INT,
  tampon_id INT,
  mg_ml INT REFERENCES pissourit_nicotine_niveaux(mg_ml),
  ajout_id BIGINT REFERENCES pissourit_ajouts(id),
  gout_sucre SMALLINT DEFAULT 0 CHECK (gout_sucre BETWEEN 0 AND 10),
  gout_sur SMALLINT DEFAULT 0 CHECK (gout_sur BETWEEN 0 AND 10),
  gout_frais SMALLINT DEFAULT 0 CHECK (gout_frais BETWEEN 0 AND 10),
  gout_piquant SMALLINT DEFAULT 0 CHECK (gout_piquant BETWEEN 0 AND 10),
  gout_sale SMALLINT DEFAULT 0 CHECK (gout_sale BETWEEN 0 AND 10),
  CHECK (gout_sucre+gout_sur+gout_frais+gout_piquant+gout_sale <= 23)
);

CREATE TABLE IF NOT EXISTS pissourit_marche (
  id BIGSERIAL PRIMARY KEY,
  vendeur_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  vape_id BIGINT NOT NULL REFERENCES pissourit_vapes(id),
  prix INT NOT NULL CHECK (prix >= 0),
  cout_copie INT NOT NULL DEFAULT 0,
  frais_livraison INT NOT NULL DEFAULT 0,
  livreur TEXT NOT NULL DEFAULT 'PAP-XPRESS',
  statut TEXT NOT NULL DEFAULT 'actif',
  cree_le TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS pissourit_recherche_police (
  user_id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  niveau SMALLINT NOT NULL DEFAULT 0,
  derniere_infraction TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS pissourit_notifications (
  id BIGSERIAL PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  pissourit_id BIGINT REFERENCES pissourits(id),
  message TEXT NOT NULL,
  lu BOOLEAN DEFAULT FALSE,
  cree_le TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS pissourit_memorial (
  pissourit_id BIGINT PRIMARY KEY REFERENCES pissourits(id),
  fiche JSONB NOT NULL,
  mort_le TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Limite de 2 Pissourits vivants par propriétaire

CREATE OR REPLACE FUNCTION pissourit_limite()
RETURNS trigger AS $$
BEGIN
  IF (
    SELECT count(*)
    FROM pissourit_owners o
    JOIN pissourits p ON p.id = o.pissourit_id
    WHERE o.user_id = NEW.user_id
      AND p.mort_le IS NULL
  ) >= 2 THEN
    RAISE EXCEPTION 'Limite de 2 Pissourits atteinte';
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_pissourit_limite ON pissourit_owners;

CREATE TRIGGER trg_pissourit_limite
BEFORE INSERT ON pissourit_owners
FOR EACH ROW EXECUTE FUNCTION pissourit_limite();

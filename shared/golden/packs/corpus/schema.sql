-- The corpus schema, copied verbatim from `sqlite_master` of assets/theology.db
-- (corpus version 16, id space 2). Hand-maintained input to
-- tools/build_pack_goldens.py, which checks it against assets/theology.db
-- whenever that file is present.
--
-- The text is kept exactly as SQLite stores it, including the columns that were
-- added later with ALTER TABLE (traditions: branch_id .. sort_order;
-- content_units: provenance). Those sit at the END of their tables, and that
-- position is load-bearing: packs are merged with a positional
-- `INSERT INTO t SELECT * FROM pack.t`, so a re-implementation that declares the
-- same columns in a tidier order will merge every row into the wrong columns.

CREATE TABLE traditions (
      id INTEGER PRIMARY KEY,
      name TEXT NOT NULL UNIQUE,
      slug TEXT NOT NULL UNIQUE,
      description TEXT,
      created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    , branch_id INTEGER REFERENCES branches(id), parent_id INTEGER REFERENCES traditions(id), full_name TEXT, sort_order INTEGER NOT NULL DEFAULT 0);

CREATE TABLE source_types (
      id INTEGER PRIMARY KEY,
      name TEXT NOT NULL UNIQUE,
      slug TEXT NOT NULL UNIQUE,
      description TEXT
    );

CREATE TABLE sources (
      id INTEGER PRIMARY KEY,
      source_type_id INTEGER NOT NULL,
      tradition_id INTEGER,
      title TEXT NOT NULL,
      slug TEXT NOT NULL UNIQUE,
      author TEXT,
      date_composed TEXT,
      date_composed_approx BOOLEAN DEFAULT 0,
      language_original TEXT,
      language_source TEXT DEFAULT 'en',
      source_url TEXT,
      license TEXT DEFAULT 'public domain',
      public_domain BOOLEAN DEFAULT 1,
      notes TEXT,
      created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
      FOREIGN KEY (source_type_id) REFERENCES source_types(id),
      FOREIGN KEY (tradition_id) REFERENCES traditions(id)
    );

CREATE TABLE authors (
      id INTEGER PRIMARY KEY,
      name TEXT NOT NULL,
      slug TEXT NOT NULL UNIQUE,
      birth_year INTEGER,
      death_year INTEGER,
      tradition_id INTEGER,
      biography TEXT,
      created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
      FOREIGN KEY (tradition_id) REFERENCES traditions(id)
    );

CREATE TABLE works (
      id INTEGER PRIMARY KEY,
      author_id INTEGER NOT NULL,
      title TEXT NOT NULL,
      slug TEXT NOT NULL UNIQUE,
      date_composed TEXT,
      language_original TEXT,
      source_url TEXT,
      public_domain BOOLEAN DEFAULT 1,
      notes TEXT,
      created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
      FOREIGN KEY (author_id) REFERENCES authors(id)
    );

CREATE TABLE content_units (
      id INTEGER PRIMARY KEY,
      source_id INTEGER NOT NULL,
      unit_type TEXT NOT NULL,
      unit_number INTEGER,
      title TEXT,
      content TEXT NOT NULL,
      parent_id INTEGER,
      sequence INTEGER NOT NULL,
      created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, provenance TEXT,
      FOREIGN KEY (source_id) REFERENCES sources(id),
      FOREIGN KEY (parent_id) REFERENCES content_units(id)
    );

CREATE TABLE tags (
      id INTEGER PRIMARY KEY,
      name TEXT NOT NULL UNIQUE,
      slug TEXT NOT NULL UNIQUE,
      category TEXT,
      description TEXT
    );

CREATE TABLE content_tags (
      content_unit_id INTEGER NOT NULL,
      tag_id INTEGER NOT NULL,
      PRIMARY KEY (content_unit_id, tag_id),
      FOREIGN KEY (content_unit_id) REFERENCES content_units(id),
      FOREIGN KEY (tag_id) REFERENCES tags(id)
    );

CREATE TABLE content_chunks (
    id INTEGER PRIMARY KEY,
    content_unit_id INTEGER NOT NULL,
    sequence INTEGER NOT NULL,
    char_start INTEGER NOT NULL,
    char_end INTEGER NOT NULL,
    FOREIGN KEY (content_unit_id) REFERENCES content_units(id)
);

CREATE TABLE chunk_embeddings (
    chunk_id INTEGER PRIMARY KEY,
    vector BLOB NOT NULL,
    FOREIGN KEY (chunk_id) REFERENCES content_chunks(id)
);

CREATE TABLE branches (
  id INTEGER PRIMARY KEY,
  slug TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL,
  description TEXT,
  split_year INTEGER,
  sort_order INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX idx_sources_type ON sources(source_type_id);
CREATE INDEX idx_sources_tradition ON sources(tradition_id);
CREATE INDEX idx_authors_tradition ON authors(tradition_id);
CREATE INDEX idx_works_author ON works(author_id);
CREATE INDEX idx_content_source ON content_units(source_id);
CREATE INDEX idx_content_parent ON content_units(parent_id);
CREATE INDEX idx_content_type ON content_units(unit_type);
CREATE INDEX idx_chunks_unit ON content_chunks(content_unit_id);

CREATE VIRTUAL TABLE content_fts USING fts5(
               content, title, content='content_units', content_rowid='id');

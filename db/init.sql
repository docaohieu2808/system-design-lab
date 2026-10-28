-- One table, and 100,000 seed links so reads hit a realistic amount of data.
CREATE TABLE links (
  id   bigserial PRIMARY KEY,
  code text NOT NULL UNIQUE,
  url  text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- Same encoding as base62() in app/main.go.
CREATE FUNCTION base62(n bigint) RETURNS text LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  chars text := '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ';
  out text := '';
BEGIN
  IF n = 0 THEN RETURN '0'; END IF;
  WHILE n > 0 LOOP
    out := substr(chars, (n % 62)::int + 1, 1) || out;
    n := n / 62;
  END LOOP;
  RETURN out;
END $$;

INSERT INTO links (id, code, url)
SELECT g, base62(g), 'https://example.com/articles/' || g
FROM generate_series(1, 100000) AS g;
SELECT setval('links_id_seq', 100000);

-- gateway-service authorization seed: api_permissions
--
-- The gateway's DatabasePermissionLoaderServiceImpl runs
--   SELECT * FROM api_permissions ORDER BY permission_name, http_method
-- on startup (LOAD_PERMISSIONS_FROM_DATABASE_ON_STARTUP=true). Without this
-- table it falls back to its bundled YAML config and authorizes nothing from DB.
--
-- Rows mirror the Dev EC2 reference environment. The RW UAT gateway routes
-- /v1/events/** -> cce-collector-service (JWT-gated), so COLLECTOR_EVENTS_WRITE
-- is the operative permission; the HTTPBIN_* rows are the test-service mappings
-- carried over from Dev for parity.
--
-- Load: docker exec -i postgres-uat psql -U admin -d ccedb < api_permissions.sql
-- Idempotent: safe to re-run.

CREATE TABLE IF NOT EXISTS public.api_permissions (
    id                bigint                      NOT NULL,
    permission_name   character varying(255)      NOT NULL,
    http_method       character varying(10)       NOT NULL,
    uri_pattern       character varying(512)      NOT NULL,
    description       text,
    resource_category character varying(255),
    created_at        timestamp without time zone DEFAULT now() NOT NULL,
    updated_at        timestamp without time zone DEFAULT now() NOT NULL
);

CREATE SEQUENCE IF NOT EXISTS public.api_permissions_id_seq
    START WITH 1 INCREMENT BY 1 NO MINVALUE NO MAXVALUE CACHE 1;
ALTER SEQUENCE public.api_permissions_id_seq OWNED BY public.api_permissions.id;
ALTER TABLE ONLY public.api_permissions
    ALTER COLUMN id SET DEFAULT nextval('public.api_permissions_id_seq'::regclass);

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'api_permissions_pkey'
    ) THEN
        ALTER TABLE ONLY public.api_permissions
            ADD CONSTRAINT api_permissions_pkey PRIMARY KEY (id);
    END IF;
END $$;

INSERT INTO public.api_permissions
    (id, permission_name, http_method, uri_pattern, description, resource_category)
VALUES
    (1, 'HTTPBIN_READ',           'GET',    '/test/**',      'Read from httpbin.org test service',    'HttpBin'),
    (2, 'HTTPBIN_WRITE',          'POST',   '/test/**',      'Post to httpbin.org test service',      'HttpBin'),
    (3, 'HTTPBIN_WRITE',          'PUT',    '/test/**',      'Update via httpbin.org test service',   'HttpBin'),
    (4, 'HTTPBIN_WRITE',          'DELETE', '/test/**',      'Delete via httpbin.org test service',   'HttpBin'),
    (5, 'COLLECTOR_EVENTS_WRITE', 'POST',   '/v1/events/**', 'Post events to collector service',      'Collector')
ON CONFLICT (id) DO NOTHING;

SELECT pg_catalog.setval('public.api_permissions_id_seq',
    (SELECT COALESCE(MAX(id), 1) FROM public.api_permissions), true);

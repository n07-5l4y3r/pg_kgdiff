CREATE FUNCTION kg_diff(from_data bytea, to_data bytea)
RETURNS bytea
LANGUAGE plpython3u
STRICT
AS $$
import pg_kgdiff1
return pg_kgdiff1.kg_diff(from_data, to_data)
$$;

CREATE FUNCTION kg_patch(from_data bytea, patch_data bytea)
RETURNS bytea
LANGUAGE plpython3u
STRICT
AS $$
import pg_kgdiff1
return pg_kgdiff1.kg_patch(from_data, patch_data)
$$;

CREATE FUNCTION kg_patch(from_data bytea, patches bytea[])
RETURNS bytea
LANGUAGE plpython3u
STRICT
AS $$
import pg_kgdiff1
return pg_kgdiff1.kg_patch_chain(from_data, patches)
$$;

CREATE FUNCTION kg_info(patch_data bytea)
RETURNS jsonb
LANGUAGE plpython3u
STRICT
AS $$
import json
import pg_kgdiff1
return json.dumps(pg_kgdiff1.kg_info(patch_data))
$$;

CREATE FUNCTION kg_selftest()
RETURNS boolean
LANGUAGE plpython3u
AS $$
import pg_kgdiff1
return pg_kgdiff1.selftest()
$$;

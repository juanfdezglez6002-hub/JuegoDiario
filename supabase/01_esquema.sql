-- =====================================================================
--  LEGENDARIO · esquema de base de datos para Supabase
--  Pégalo entero en Supabase → SQL Editor → Run. Se puede ejecutar
--  más de una vez sin romper nada (recrea las funciones).
--
--  Seguridad:
--   · Las tablas viven en el esquema "privado", que la API de Supabase
--     NO expone. Además tienen RLS activado y sin políticas: nadie puede
--     leerlas ni escribirlas desde el navegador.
--   · La web solo puede llamar a las funciones públicas de abajo
--     (SECURITY DEFINER), que validan todo en el servidor.
--   · En la web solo va la clave pública (anon / publishable).
--     La clave de servicio (service_role / secret) NUNCA va en la web.
--   · Antitrampas: huella de red (hash de la IP con una sal que cambia
--     cada día y se borra a las 48 h, nunca se guarda la IP), límite de
--     jugadores por red y pregunta, freno de peticiones por minuto y
--     votos sin duplicar (una red cuenta una vez por respuesta y día).
-- =====================================================================

create extension if not exists unaccent with schema extensions;
create extension if not exists fuzzystrmatch with schema extensions;

create schema if not exists privado;
revoke all on schema privado from public, anon, authenticated;

-- ---------- TABLAS ----------
create table if not exists privado.juegos (
  id      text primary key,
  nombre  text not null,
  icono   text not null default '🎮',
  activo  boolean not null default true,
  desde   date not null default current_date,
  info    jsonb not null default '{}'::jsonb,
  extra   text[] not null default '{}',      -- nombres señuelo para el autocompletado
  orden   int not null default 0
);

create table if not exists privado.preguntas (
  id       text primary key,
  juego_id text not null references privado.juegos(id),
  texto    text not null,
  activo   boolean not null default true,
  desde    date not null default current_date
);

create table if not exists privado.respuestas (
  id          bigint generated always as identity primary key,
  pregunta_id text not null references privado.preguntas(id),
  nombre      text not null,
  alias       text[] not null default '{}',
  rareza      char(1) not null check (rareza in ('c','r','e','l')),  -- rareza inicial (punto de partida)
  activo      boolean not null default true,
  clave       text not null,        -- nombre normalizado (lo rellena un trigger)
  claves      text[] not null,      -- nombre + alias normalizados (lo rellena un trigger)
  unique (pregunta_id, clave)
);

create table if not exists privado.retos (
  dia         date not null,
  posicion    int  not null,
  pregunta_id text not null references privado.preguntas(id),
  primary key (dia, posicion),
  unique (dia, pregunta_id)
);

create table if not exists privado.participaciones (
  dia          date not null,
  pregunta_id  text not null references privado.preguntas(id),
  jugador      uuid not null,
  inicio       timestamptz not null default now(),
  estado       text not null default 'pendiente' check (estado in ('pendiente','ok','pasada','tiempo')),
  respuesta_id bigint references privado.respuestas(id),
  segundos     numeric(4,1),
  intentos     int not null default 0,
  fin          timestamptz,
  primary key (dia, pregunta_id, jugador)
);
create index if not exists participaciones_votos on privado.participaciones (pregunta_id, estado, dia, respuesta_id);
alter table privado.participaciones add column if not exists red text;   -- huella de red (hash), nunca la IP
create index if not exists participaciones_red on privado.participaciones (dia, pregunta_id, red);

-- Respuestas que los jugadores escribieron y el juego NO reconoció.
-- Sirve para descubrir alias que faltan ("netherita", "tilted", nombres en inglés…).
-- NO se guarda quién lo escribió: solo el texto, cuántas veces y cuándo.
create table if not exists privado.rechazos (
  pregunta_id text not null references privado.preguntas(id),
  clave       text not null,                    -- texto normalizado (agrupa mayúsculas, tildes y erratas de formato)
  texto       text not null,                    -- tal y como lo escribió el primer jugador
  veces       int not null default 1,
  primera     timestamptz not null default now(),
  ultima      timestamptz not null default now(),
  ignorar     boolean not null default false,   -- ponlo a true para que no vuelva a salir en la lista de revisión
  primary key (pregunta_id, clave)
);
create index if not exists rechazos_veces on privado.rechazos (veces desc);

-- sal diaria para la huella de red (se borra pasado un día: después la huella ya no se puede relacionar con ninguna IP)
create table if not exists privado.sal_diaria (
  dia date primary key,
  sal text not null default gen_random_uuid()::text
);
-- contador de peticiones por red y minuto (se limpia solo)
create table if not exists privado.peticiones (
  red    text not null,
  minuto timestamptz not null,
  n      int not null default 0,
  primary key (red, minuto)
);

alter table privado.juegos          enable row level security;
alter table privado.preguntas       enable row level security;
alter table privado.respuestas      enable row level security;
alter table privado.retos           enable row level security;
alter table privado.participaciones enable row level security;
alter table privado.rechazos        enable row level security;
alter table privado.sal_diaria      enable row level security;
alter table privado.peticiones      enable row level security;
revoke all on all tables in schema privado from public, anon, authenticated;

-- ---------- AJUSTES DEL JUEGO ----------
create or replace function privado.ajuste(k text) returns numeric
language sql immutable as $$
  select case k
    when 'segundos'       then 30     -- tiempo por pregunta
    when 'margen'         then 3      -- segundos de cortesía por la latencia
    when 'preguntas_dia'  then 5
    when 'peso_inicial'   then 30     -- "jugadores imaginarios" de la rareza inicial
    when 'max_intentos'   then 60     -- intentos fallidos por pregunta (anti-spam)
    when 'max_por_minuto' then 90     -- peticiones por minuto desde una misma red
    when 'max_red'        then 4      -- jugadores distintos por red y pregunta al día (familias, wifi compartida…)
    when 'pct_min'        then 0.3    -- % a partir del cual ya das 100 puntos
    when 'margen_practica' then 3     -- la práctica no usa preguntas del reto de hoy ni de los próximos N días
    -- % de jugadores que se supone que dicen una respuesta según su rareza inicial
    when 'previo_c' then 25  when 'previo_r' then 8  when 'previo_e' then 2.5  when 'previo_l' then 0.5
    -- umbrales del nivel según el % real
    when 'umbral_c' then 15  when 'umbral_r' then 4  when 'umbral_e' then 1
  end
$$;

create or replace function privado.hoy() returns date
language sql stable as $$ select (now() at time zone 'Europe/Madrid')::date $$;

-- Huella de red: hash(IP + sal del día). Nunca se guarda la IP.
-- cf-connecting-ip la pone Cloudflare (delante de Supabase) y el navegador no puede falsearla;
-- x-forwarded-for solo se usa como último recurso porque sí se puede falsear.
create or replace function privado.red() returns text
language plpgsql volatile as $$
declare h jsonb; ip text; s text;
begin
  begin h := nullif(current_setting('request.headers', true), '')::jsonb; exception when others then h := null; end;
  if h is null then return null; end if;
  ip := coalesce(nullif(trim(h->>'cf-connecting-ip'),''), nullif(trim(h->>'x-real-ip'),''),
                 nullif(trim(split_part(h->>'x-forwarded-for', ',', 1)),''));
  if ip is null then return null; end if;
  insert into privado.sal_diaria (dia) values (privado.hoy()) on conflict do nothing;
  select sal into s from privado.sal_diaria where dia = privado.hoy();
  if random() < 0.01 then delete from privado.sal_diaria where dia < privado.hoy() - 1; end if;
  return encode(sha256(convert_to(ip || '|' || s, 'UTF8')), 'hex');
end $$;

-- Freno de peticiones: como máximo max_por_minuto llamadas por red y minuto
create or replace function privado.frenar() returns text
language plpgsql volatile as $$
declare r text := privado.red(); n int;
begin
  if r is null then return null; end if;
  insert into privado.peticiones (red, minuto, n) values (r, date_trunc('minute', now()), 1)
    on conflict (red, minuto) do update set n = privado.peticiones.n + 1
    returning privado.peticiones.n into n;
  if random() < 0.02 then delete from privado.peticiones where minuto < now() - interval '10 minutes'; end if;
  if n > privado.ajuste('max_por_minuto') then raise exception 'demasiadas_peticiones'; end if;
  return r;
end $$;

-- Igual que norm() del JavaScript: sin tildes, minúsculas, sin artículos iniciales, solo letras y números
create or replace function privado.norm(t text) returns text
language plpgsql immutable as $$
declare s text; prev text;
begin
  s := trim(lower(extensions.unaccent('extensions.unaccent'::regdictionary, coalesce(t,''))));
  loop
    prev := s;
    s := regexp_replace(s, '^(el|la|los|las|the|un|una|copa)\s+', '');
    exit when s = prev;
  end loop;
  return regexp_replace(s, '[^a-z0-9]', '', 'g');
end $$;

create or replace function privado.respuestas_claves() returns trigger
language plpgsql as $$
begin
  new.clave  := privado.norm(new.nombre);
  new.claves := array(select distinct k from unnest(array[new.nombre] || coalesce(new.alias,'{}')) a, privado.norm(a) k where k <> '');
  return new;
end $$;
drop trigger if exists respuestas_claves on privado.respuestas;
create trigger respuestas_claves before insert or update of nombre, alias on privado.respuestas
  for each row execute function privado.respuestas_claves();

-- Busca qué respuesta válida corresponde a lo escrito (exacto o con erratas pequeñas)
create or replace function privado.buscar(p_pregunta text, p_texto text) returns bigint
language plpgsql stable as $$
declare n text := privado.norm(p_texto); r bigint;
begin
  if n = '' then return null; end if;
  select id into r from privado.respuestas
   where pregunta_id = p_pregunta and activo and n = any(claves) limit 1;
  if r is not null then return r; end if;
  select id into r from (
    select x.id, extensions.levenshtein(n, k) d,
           case when length(k) <= 4 then 0 when length(k) <= 8 then 1 else 2 end permitido
      from privado.respuestas x, unnest(x.claves) k
     where x.pregunta_id = p_pregunta and x.activo and abs(length(k) - length(n)) <= 2
  ) t where permitido > 0 and d <= permitido order by d limit 1;
  return r;
end $$;

-- Rareza de todas las respuestas de una pregunta con los votos hasta p_hasta (incluido).
--   % estimado = mezcla entre el % inicial (según rareza) y el % real.
--   Con pocos votos manda la rareza inicial; con muchos, los datos reales.
--   puntos = 100 − %   ·   nivel según umbrales
--   p_excluir: jugador cuyo voto no cuenta (tu rareza = lo que dijeron LOS DEMÁS).
--   Votos sin duplicar: una misma red cuenta como mucho 1 voto por respuesta y día.
--   Puntos en escala logarítmica: 100 puntos con pct_min (0,3%) o menos, 0 puntos con el 100%.
--     ej.: 45% → 14 · 14% → 34 · 4% → 55 · 1% → 79 · 0,5% → 91
drop function if exists privado.calcular(text, date);
drop function if exists privado.calcular(text, date, uuid);
create or replace function privado.calcular(p_pregunta text, p_hasta date, p_excluir uuid default null)
returns table (respuesta_id bigint, nombre text, votos bigint, pct numeric, puntos int, nivel char(1))
language sql stable as $$
  with v as (
    select respuesta_id, count(distinct dia::text || '|' || coalesce(red, jugador::text)) n from privado.participaciones
     where pregunta_id = p_pregunta and estado = 'ok' and dia <= p_hasta
       and jugador is distinct from p_excluir group by respuesta_id
  ), tot as (select coalesce(sum(n),0)::numeric t from v),
  base as (
    select r.id, r.nombre, coalesce(v.n,0) n, privado.ajuste('previo_'||r.rareza) previo
      from privado.respuestas r left join v on v.respuesta_id = r.id
     where r.pregunta_id = p_pregunta and (r.activo or v.n > 0)
  ), mix as (
    select b.*, (select t from tot) t,
           privado.ajuste('peso_inicial') / (privado.ajuste('peso_inicial') + (select t from tot)) w
      from base b
  ), fin as (
    select id, nombre, n,
           round(w*previo + (1-w)*(case when t > 0 then n*100.0/t else 0 end), 1) p
      from mix
  )
  select id, nombre, n, p,
         greatest(0, least(100, round(100 * (1 - ln(greatest(p, privado.ajuste('pct_min')) / privado.ajuste('pct_min'))
                                             / ln(100 / privado.ajuste('pct_min'))))))::int,
         (case when p >= privado.ajuste('umbral_c') then 'c'
               when p >= privado.ajuste('umbral_r') then 'r'
               when p >= privado.ajuste('umbral_e') then 'e' else 'l' end)::char(1)
    from fin
$$;

-- Crea el reto del día si no está planificado: juegos al azar,
-- y en cada juego la pregunta menos usada (empate → al azar).
create or replace function privado.asegurar_reto(p_dia date) returns void
language plpgsql as $$
declare g record; q text; pos int := 0;
begin
  if exists (select 1 from privado.retos where dia = p_dia) then return; end if;
  perform pg_advisory_xact_lock(hashtext('legendario-reto-' || p_dia));
  if exists (select 1 from privado.retos where dia = p_dia) then return; end if;
  for g in
    select j.id from privado.juegos j
     where j.activo and j.desde <= p_dia
       and exists (select 1 from privado.preguntas p where p.juego_id = j.id and p.activo and p.desde <= p_dia
                     and exists (select 1 from privado.respuestas r where r.pregunta_id = p.id and r.activo))
     order by random() limit privado.ajuste('preguntas_dia')::int
  loop
    select p.id into q from privado.preguntas p
     where p.juego_id = g.id and p.activo and p.desde <= p_dia
       and exists (select 1 from privado.respuestas r where r.pregunta_id = p.id and r.activo)
     order by (select count(*) from privado.retos x where x.pregunta_id = p.id),
              (select max(x.dia) from privado.retos x where x.pregunta_id = p.id) nulls first,
              random()
     limit 1;
    pos := pos + 1;
    insert into privado.retos (dia, posicion, pregunta_id) values (p_dia, pos, q);
  end loop;
end $$;

create or replace function privado.resultado_json(p_dia date, p_pregunta text, p_jugador uuid) returns jsonb
language sql stable as $$
  select jsonb_build_object(
    'estado', pa.estado, 'segundos', pa.segundos, 'respuesta', c.nombre,
    'pct', c.pct, 'puntos', coalesce(c.puntos, 0), 'nivel', c.nivel)
  from privado.participaciones pa
  left join lateral (select * from privado.calcular(p_pregunta, p_dia, p_jugador) k where k.respuesta_id = pa.respuesta_id) c on true
  where pa.dia = p_dia and pa.pregunta_id = p_pregunta and pa.jugador = p_jugador
$$;

-- Anota una respuesta no reconocida. La llaman responder() y responder_practica().
create or replace function privado.anotar_rechazo(p_pregunta text, p_texto text) returns void
language plpgsql as $$
declare k text := privado.norm(p_texto);
begin
  if length(k) < 2 or length(k) > 40 then return; end if;   -- ignora pulsaciones sueltas y churros
  insert into privado.rechazos (pregunta_id, clave, texto) values (p_pregunta, k, left(btrim(p_texto), 60))
  on conflict (pregunta_id, clave) do update set veces = privado.rechazos.veces + 1, ultima = now();
exception when others then return;
end $$;

-- ---------- REVISAR LO QUE LA GENTE ESCRIBE (ejecútalo tú en el SQL Editor) ----------
--   select * from privado.rechazos_top();          · lo más escrito y no reconocido
--   select * from privado.rechazos_top(3);         · solo lo que se repitió 3 veces o más
--   select * from privado.rechazos_resumen();      · qué preguntas generan más rechazos
-- Lo que ya hayas resuelto añadiendo un alias desaparece solo de la lista.
-- Para esconder algo que no es una respuesta válida:
--   update privado.rechazos set ignorar = true where clave = 'loquesea';
create or replace function privado.rechazos_top(p_min int default 1, p_limite int default 100)
returns table (juego text, pregunta text, escribieron text, veces int, ultima date, mas_parecido text, distancia int)
language sql stable as $$
  select j.nombre, p.texto, r.texto, r.veces, r.ultima::date, c.nombre, c.d
    from privado.rechazos r
    join privado.preguntas p on p.id = r.pregunta_id
    join privado.juegos   j on j.id = p.juego_id
    left join lateral (
      select x.nombre, min(extensions.levenshtein(r.clave, k))::int d
        from privado.respuestas x, unnest(x.claves) k
       where x.pregunta_id = r.pregunta_id and x.activo
       group by x.nombre order by d limit 1
    ) c on true
   where not r.ignorar and r.veces >= p_min
     and privado.buscar(r.pregunta_id, r.texto) is null
   order by r.veces desc, r.ultima desc
   limit p_limite
$$;

create or replace function privado.rechazos_resumen()
returns table (juego text, pregunta text, textos_distintos int, intentos_totales int)
language sql stable as $$
  select j.nombre, p.texto, count(*)::int, sum(r.veces)::int
    from privado.rechazos r
    join privado.preguntas p on p.id = r.pregunta_id
    join privado.juegos   j on j.id = p.juego_id
   where not r.ignorar and privado.buscar(r.pregunta_id, r.texto) is null
   group by j.nombre, p.texto
   order by 4 desc
$$;

-- =====================================================================
--  FUNCIONES PÚBLICAS (las que llama la web)
-- =====================================================================

-- Juegos activos, su ficha y los nombres para el autocompletado
create or replace function public.catalogo() returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'hoy', privado.hoy(),
    'segundos', privado.ajuste('segundos'),
    'juegos', coalesce(jsonb_agg(jsonb_build_object(
        'id', j.id, 'nombre', j.nombre, 'icono', j.icono, 'info', j.info,
        'nombres', (select coalesce(jsonb_agg(distinct x), '[]'::jsonb) from (
            select array_to_string(array[r.nombre] || r.alias, '|') x
              from privado.respuestas r join privado.preguntas p on p.id = r.pregunta_id
             where p.juego_id = j.id and r.activo and p.activo
            union select e from unnest(j.extra) e) s)
      ) order by j.orden, j.nombre), '[]'::jsonb))
  from privado.juegos j
  where j.activo and j.desde <= privado.hoy()
    and exists (select 1 from privado.preguntas p where p.juego_id = j.id and p.activo and p.desde <= privado.hoy())
$$;

-- Reto de hoy con el estado de cada pregunta para este jugador
create or replace function public.obtener_reto(p_jugador uuid) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare d date := privado.hoy();
begin
  if p_jugador is null then raise exception 'falta_jugador'; end if;
  perform privado.frenar();
  perform privado.asegurar_reto(d);
  -- cierra por tiempo las preguntas que se quedaron a medias
  update privado.participaciones set estado = 'tiempo', fin = now()
   where dia = d and jugador = p_jugador and estado = 'pendiente'
     and now() - inicio > make_interval(secs => privado.ajuste('segundos') + privado.ajuste('margen'));
  return jsonb_build_object('dia', d, 'preguntas', coalesce((
    select jsonb_agg(jsonb_build_object(
      'posicion', r.posicion, 'pregunta_id', p.id, 'juego_id', p.juego_id, 'texto', p.texto,
      'n', (select count(*) from privado.respuestas x where x.pregunta_id = p.id and x.activo),
      'resultado', privado.resultado_json(d, p.id, p_jugador)) order by r.posicion)
    from privado.retos r join privado.preguntas p on p.id = r.pregunta_id where r.dia = d), '[]'::jsonb));
end $$;

-- Empieza (o retoma) una pregunta: el temporizador lo lleva el servidor
create or replace function public.empezar(p_jugador uuid, p_pregunta text) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare d date := privado.hoy(); pa privado.participaciones; restan numeric; r text;
begin
  if p_jugador is null then raise exception 'falta_jugador'; end if;
  r := privado.frenar();
  if not exists (select 1 from privado.retos where dia = d and pregunta_id = p_pregunta) then raise exception 'pregunta_no_es_de_hoy'; end if;
  if r is not null
     and not exists (select 1 from privado.participaciones where dia = d and pregunta_id = p_pregunta and jugador = p_jugador)
     and (select count(distinct jugador) from privado.participaciones where dia = d and pregunta_id = p_pregunta and red = r)
         >= privado.ajuste('max_red') then
    raise exception 'limite_red';
  end if;
  insert into privado.participaciones (dia, pregunta_id, jugador, red) values (d, p_pregunta, p_jugador, r) on conflict do nothing;
  select * into pa from privado.participaciones where dia = d and pregunta_id = p_pregunta and jugador = p_jugador for update;
  restan := privado.ajuste('segundos') - extract(epoch from now() - pa.inicio);
  if pa.estado = 'pendiente' and restan < -privado.ajuste('margen') then
    update privado.participaciones set estado = 'tiempo', fin = now() where dia = d and pregunta_id = p_pregunta and jugador = p_jugador;
  end if;
  return jsonb_build_object('restan', greatest(0, round(restan, 1))) || privado.resultado_json(d, p_pregunta, p_jugador);
end $$;

-- Comprueba una respuesta. Si vale, guarda el voto y devuelve nivel, % y puntos provisionales.
create or replace function public.responder(p_jugador uuid, p_pregunta text, p_texto text) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare d date := privado.hoy(); pa privado.participaciones; rid bigint; seg numeric;
begin
  if p_jugador is null then raise exception 'falta_jugador'; end if;
  perform privado.frenar();
  if p_texto is null or length(p_texto) = 0 or length(p_texto) > 60 then return jsonb_build_object('valida', false); end if;
  select * into pa from privado.participaciones where dia = d and pregunta_id = p_pregunta and jugador = p_jugador for update;
  if not found then raise exception 'no_empezada'; end if;
  if pa.estado <> 'pendiente' then return jsonb_build_object('valida', pa.estado = 'ok') || privado.resultado_json(d, p_pregunta, p_jugador); end if;
  seg := extract(epoch from now() - pa.inicio);
  if seg > privado.ajuste('segundos') + privado.ajuste('margen') then
    update privado.participaciones set estado = 'tiempo', fin = now() where dia = d and pregunta_id = p_pregunta and jugador = p_jugador;
    return jsonb_build_object('valida', false) || privado.resultado_json(d, p_pregunta, p_jugador);
  end if;
  if pa.intentos >= privado.ajuste('max_intentos') then return jsonb_build_object('valida', false, 'error', 'demasiados_intentos'); end if;
  rid := privado.buscar(p_pregunta, p_texto);
  if rid is null then
    perform privado.anotar_rechazo(p_pregunta, p_texto);
    update privado.participaciones set intentos = intentos + 1 where dia = d and pregunta_id = p_pregunta and jugador = p_jugador;
    return jsonb_build_object('valida', false, 'estado', 'pendiente');
  end if;
  update privado.participaciones
     set estado = 'ok', respuesta_id = rid, segundos = least(privado.ajuste('segundos'), round(seg, 1)), fin = now()
   where dia = d and pregunta_id = p_pregunta and jugador = p_jugador;
  return jsonb_build_object('valida', true) || privado.resultado_json(d, p_pregunta, p_jugador);
end $$;

-- Pasar una pregunta o cerrarla porque se acabó el tiempo
create or replace function public.pasar(p_jugador uuid, p_pregunta text, p_motivo text default 'pasada') returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare d date := privado.hoy();
begin
  perform privado.frenar();
  update privado.participaciones
     set estado = case when p_motivo = 'tiempo' then 'tiempo' else 'pasada' end, fin = now()
   where dia = d and pregunta_id = p_pregunta and jugador = p_jugador and estado = 'pendiente';
  return coalesce(privado.resultado_json(d, p_pregunta, p_jugador), '{}'::jsonb);
end $$;

-- Resultados de un día: tu respuesta y TODAS las respuestas con su %.
-- Las respuestas de una pregunta de hoy solo se enseñan si ya la has jugado.
-- Los días anteriores son definitivos.
create or replace function public.resultados_dia(p_jugador uuid, p_dia date default null) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare d date := coalesce(p_dia, privado.hoy());
begin
  perform privado.frenar();
  if d > privado.hoy() then raise exception 'dia_futuro'; end if;
  return jsonb_build_object('dia', d, 'definitivo', d < privado.hoy(), 'preguntas', coalesce((
    select jsonb_agg(jsonb_build_object(
      'posicion', r.posicion, 'pregunta_id', p.id, 'juego_id', p.juego_id, 'texto', p.texto,
      'resultado', privado.resultado_json(d, p.id, p_jugador),
      'jugadores', (select count(distinct x.dia::text || '|' || coalesce(x.red, x.jugador::text)) from privado.participaciones x
                     where x.pregunta_id = p.id and x.estado = 'ok' and x.dia <= d and x.jugador <> p_jugador),
      'todas', case when d < privado.hoy() or exists (
                 select 1 from privado.participaciones x where x.dia = d and x.pregunta_id = p.id and x.jugador = p_jugador and x.estado <> 'pendiente')
               then (select jsonb_agg(jsonb_build_object('nombre', c.nombre, 'pct', c.pct, 'puntos', c.puntos, 'nivel', c.nivel) order by c.pct, c.nombre)
                       from privado.calcular(p.id, d, p_jugador) c)
               end) order by r.posicion)
    from privado.retos r join privado.preguntas p on p.id = r.pregunta_id where r.dia = d), '[]'::jsonb));
end $$;

-- ---------- PRÁCTICA (no guarda votos; nunca usa preguntas del reto de hoy ni de los próximos días) ----------
create or replace function public.preguntas_practica(p_juego text default null) returns jsonb
language sql volatile security definer set search_path = '' as $$
  select privado.frenar();
  select coalesce(jsonb_agg(x), '[]'::jsonb) from (
    select jsonb_build_object('pregunta_id', p.id, 'juego_id', p.juego_id, 'texto', p.texto,
             'n', (select count(*) from privado.respuestas r where r.pregunta_id = p.id and r.activo)) x
      from privado.preguntas p join privado.juegos j on j.id = p.juego_id
     where p.activo and j.activo and p.desde <= privado.hoy() and j.desde <= privado.hoy()
       and (p_juego is null or p.juego_id = p_juego)
       and not exists (select 1 from privado.retos r where r.pregunta_id = p.id and r.dia between privado.hoy() and privado.hoy() + privado.ajuste('margen_practica')::int)
       and exists (select 1 from privado.respuestas r where r.pregunta_id = p.id and r.activo)
     order by random() limit 5) s
$$;

create or replace function public.responder_practica(p_pregunta text, p_texto text) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$  -- volatile: anota las respuestas no reconocidas
declare rid bigint; c record;
begin
  perform privado.frenar();
  if exists (select 1 from privado.retos r where r.pregunta_id = p_pregunta and r.dia between privado.hoy() and privado.hoy() + privado.ajuste('margen_practica')::int) then raise exception 'no_disponible'; end if;
  if p_texto is null or length(p_texto) = 0 or length(p_texto) > 60 then return jsonb_build_object('valida', false); end if;
  rid := privado.buscar(p_pregunta, p_texto);
  if rid is null then perform privado.anotar_rechazo(p_pregunta, p_texto); return jsonb_build_object('valida', false); end if;
  select * into c from privado.calcular(p_pregunta, privado.hoy()) k where k.respuesta_id = rid;
  return jsonb_build_object('valida', true, 'estado', 'ok', 'respuesta', c.nombre, 'pct', c.pct, 'puntos', c.puntos, 'nivel', c.nivel);
end $$;

create or replace function public.respuestas_practica(p_pregunta text) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
begin
  perform privado.frenar();
  if exists (select 1 from privado.retos r where r.pregunta_id = p_pregunta and r.dia between privado.hoy() and privado.hoy() + privado.ajuste('margen_practica')::int) then raise exception 'no_disponible'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('nombre', c.nombre, 'pct', c.pct, 'puntos', c.puntos, 'nivel', c.nivel) order by c.pct, c.nombre), '[]'::jsonb)
            from privado.calcular(p_pregunta, privado.hoy()) c);
end $$;

-- ---------- PERMISOS ----------
revoke all on all functions in schema privado from public, anon, authenticated;
revoke all on function public.catalogo(), public.obtener_reto(uuid), public.empezar(uuid,text), public.responder(uuid,text,text),
  public.pasar(uuid,text,text), public.resultados_dia(uuid,date), public.preguntas_practica(text),
  public.responder_practica(text,text), public.respuestas_practica(text) from public;
grant execute on function public.catalogo(), public.obtener_reto(uuid), public.empezar(uuid,text), public.responder(uuid,text,text),
  public.pasar(uuid,text,text), public.resultados_dia(uuid,date), public.preguntas_practica(text),
  public.responder_practica(text,text), public.respuestas_practica(text) to anon, authenticated;

-- LogiTrack — migração para pedidos com cargas flexíveis
-- Aplicar uma vez no Supabase SQL Editor, após o instalador LogiTrack atual.
-- Mantém os pedidos antigos e a validação de estoque/equipamentos quando usada.

begin;

alter table public.pedidos
    add column if not exists descricao_carga text not null default '',
    add column if not exists usa_equipamentos boolean not null default true;

comment on column public.pedidos.descricao_carga is
    'Descrição obrigatória da mercadoria e quantidade a transportar.';
comment on column public.pedidos.usa_equipamentos is
    'Indica se o pedido inclui cavaletes, lonas, forros ou cintas controlados pelo sistema.';

-- Nova RPC: permite registrar cargas sem os equipamentos controlados.
-- Quando os equipamentos forem usados, preserva a baixa e a validação do estoque
-- da RPC já existente criar_pedido_com_estoque.
create or replace function public.criar_pedido_flexivel(
    p jsonb,
    p_usa_equipamentos boolean default false,
    p_kit_proprio boolean default false,
    p_estoque_cidade text default null
) returns bigint
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_id bigint;
    v_usa boolean := coalesce(p_usa_equipamentos, false);
    v_kit boolean := coalesce(p_kit_proprio, false);
    v_descricao text := btrim(coalesce(p ->> 'descricaoCarga', ''));
begin
    if length(v_descricao) < 3 then
        raise exception 'Descreva a mercadoria e a quantidade do pedido.'
            using errcode = '23502';
    end if;

    -- A função existente continua sendo responsável pela patente e pelo
    -- registro atômico dos equipamentos/estoque, quando aplicável.
    v_id := public.criar_pedido_com_estoque(
        p,
        (not v_usa) or v_kit,
        case when v_usa and not v_kit then p_estoque_cidade else null end
    );

    update public.pedidos
       set descricao_carga = v_descricao,
           usa_equipamentos = v_usa,
           kit_proprio = case when v_usa then v_kit else false end,
           estoque_cidade = case when v_usa and not v_kit then p_estoque_cidade else null end
     where id = v_id;

    return v_id;
end;
$$;

grant execute on function public.criar_pedido_flexivel(jsonb, boolean, boolean, text)
    to authenticated;

-- Edição do administrador: mantém as regras da função existente e persiste
-- também descrição e indicador de equipamentos.
create or replace function public.editar_pedido_flexivel(p_id bigint, p jsonb)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
    if p ? 'descricaoCarga' and length(btrim(coalesce(p ->> 'descricaoCarga', ''))) < 3 then
        raise exception 'Descreva a mercadoria e a quantidade do pedido.'
            using errcode = '23502';
    end if;

    perform public.editar_pedido(p_id, p);

    update public.pedidos
       set descricao_carga = case
               when p ? 'descricaoCarga' then btrim(p ->> 'descricaoCarga')
               else descricao_carga
           end,
           usa_equipamentos = case
               when p ? 'usaEquipamentos' then coalesce((p ->> 'usaEquipamentos')::boolean, usa_equipamentos)
               else usa_equipamentos
           end
     where id = p_id;
end;
$$;

grant execute on function public.editar_pedido_flexivel(bigint, jsonb)
    to authenticated;

-- Acrescenta os dois campos ao JSON de leitura já existente, sem substituir
-- o restante da função carregar_dados nem perder campos implantados antes.
do $patch$
declare
    v_def text;
begin
    select pg_get_functiondef(p.oid)
      into v_def
      from pg_proc p
     where p.pronamespace = 'public'::regnamespace
       and p.proname = 'carregar_dados'
       and p.pronargs = 0
     order by p.oid desc
     limit 1;

    if v_def is null then
        raise exception 'Função public.carregar_dados() não encontrada.';
    end if;

    if position('p.descricao_carga' in v_def) = 0 then
        if position('''cintas'', p.cintas,' in v_def) = 0 then
            raise exception 'Não foi possível localizar o trecho esperado de pedidos em carregar_dados().';
        end if;
        v_def := replace(
            v_def,
            '''cintas'', p.cintas,',
            '''cintas'', p.cintas, ''descricaoCarga'', p.descricao_carga, ''usaEquipamentos'', p.usa_equipamentos,'
        );
        execute v_def;
    end if;
end;
$patch$;

commit;

-- Notificações push não são enviadas por esta migração: o sistema atual não
-- possui cadastro/vínculo obrigatório do motorista a uma conta e dispositivo,
-- subscrição push nem serviço de entrega com credenciais VAPID.

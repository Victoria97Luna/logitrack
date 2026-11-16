-- LogiTrack — correção aditiva para gravação de pedidos flexíveis
-- Reexecutável. Não remove nem substitui os fluxos existentes de pedido/estoque.
-- Executar no Supabase SQL Editor após o instalador principal.

begin;

alter table public.pedidos
    add column if not exists descricao_carga text not null default '',
    add column if not exists usa_equipamentos boolean not null default true;

do $$
begin
    if to_regprocedure('public.criar_pedido_com_estoque(jsonb,boolean,text)') is null then
        raise exception 'Função criar_pedido_com_estoque(jsonb, boolean, text) não encontrada. Aplique primeiro o instalador LogiTrack atualizado.';
    end if;
end;
$$;

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

    if not v_usa then
        -- Não chamar a rotina antiga neste caso: a regra legada normaliza
        -- 0 cavaletes para 1 e tentaria baixar cintas que não serão usadas.
        perform public._exigir_lancar_pedido();

        if coalesce(btrim(p ->> 'numero'), '') = '' then
            raise exception 'O número do pedido é obrigatório.' using errcode = '23502';
        end if;
        if coalesce(btrim(p ->> 'cliente'), '') = '' then
            raise exception 'O cliente é obrigatório.' using errcode = '23502';
        end if;

        v_end := btrim(coalesce(p ->> 'endereco', ''));
        if v_end = '' or length(v_end) < 10 or v_end !~ '[0-9]' then
            raise exception 'Informe o endereço completo, incluindo número e bairro.' using errcode = '22023';
        end if;
        if coalesce(btrim(p ->> 'cidade'), '') = '' or coalesce(btrim(p ->> 'uf'), '') = '' then
            raise exception 'Cidade e estado (UF) são obrigatórios.' using errcode = '23502';
        end if;

        insert into public.pedidos (
            id, numero, cliente, cidade, uf, endereco, veiculo, placa, motorista,
            data, horario, cavaletes, lonas, forros, cintas, cintas_novas, cintas_usadas,
            lacres_lona, lacres_forro, entregue, data_entrega,
            coleta_cavalete_pendente, coleta_lona_pendente,
            quem_coletou_cavalete, quem_coletou_lona,
            descricao_carga, usa_equipamentos, kit_proprio, estoque_cidade
        ) values (
            coalesce(nullif(p ->> 'id', '')::bigint,
                     nextval(pg_get_serial_sequence('public.pedidos', 'id'))),
            btrim(p ->> 'numero'),
            btrim(p ->> 'cliente'),
            btrim(p ->> 'cidade'),
            upper(btrim(p ->> 'uf')),
            v_end,
            coalesce(nullif(p ->> 'veiculo', ''), 'BITRUCK'),
            upper(coalesce(nullif(btrim(p ->> 'placa'), ''), '---')),
            coalesce(nullif(btrim(p ->> 'motorista'), ''), '---'),
            coalesce(public._para_data(p ->> 'data'), current_date),
            public._para_hora(p ->> 'horario'),
            0, 0, 0, 0, 0, 0,
            '{}'::text[], '{}'::text[],
            false, null,
            false, false,
            null, null,
            v_descricao, false, false, null
        )
        returning id into v_id;

        return v_id;
    end if;

    -- Para pedidos com equipamentos, reutiliza a rotina existente e preserva
    -- suas validações de lacres, cintas, acesso e baixa do estoque.
    v_id := public.criar_pedido_com_estoque(
        p,
        v_kit,
        case when not v_kit then p_estoque_cidade else null end
    );

    update public.pedidos
       set descricao_carga = v_descricao,
           usa_equipamentos = true,
           kit_proprio = v_kit,
           estoque_cidade = case when not v_kit then p_estoque_cidade else null end
     where id = v_id;

    return v_id;
end;
$$;

grant execute on function public.criar_pedido_flexivel(jsonb, boolean, boolean, text)
    to authenticated;

notify pgrst, 'reload schema';
commit;

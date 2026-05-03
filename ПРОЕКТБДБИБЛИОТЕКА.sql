create schema library;

create table library.book_type(
	type_id		serial		primary key,
	type		varchar(30) not null unique --альтернативный ключ (авторское, анонимное, фольклор, религия, законы)
);

create table library.books(
	book_id				serial			primary key,
	title 				varchar(200)	not null, 
  	available_copies	integer			not null check (available_copies >= 0), 
  	isbn				varchar(20)		null unique, --альтернативный ключ
  	type_id				int				not null references library.book_type(type_id)
  										on delete restrict 
										on update cascade
);

create table library.authors(
    author_id	serial			primary key,
    full_name	varchar(100) 	not null unique
);

create table library.books_author(
	author_id	int				not null references library.authors(author_id) 
								on delete restrict 
								on update cascade,
	book_id		int				not null references library.books(book_id) 
								on delete restrict 
								on update cascade,
	constraint author_book_unq primary key (author_id, book_id)
);

create table library.copy_of_the_book(
	copy_id		serial	primary key, --первичный
	book_id		int		not null references library.books(book_id) 
						on delete restrict 
						on update cascade,
	available	bool	not null
);

create table library.readers(
  reader_id		serial			primary key,
  email			varchar(320)	not null unique check(email ~* '^[A-Za-z0-9._%+-]{1,64}@[A-Za-z0-9.-]{1,239}\.[A-Za-z]{2,16}$'), --шаблон почты  огарниением на длину домена и верхнего домена
  phone_number	varchar(14)		not null unique check(phone_number ~ '^8\([0-9]{3}\)[0-9]{3}-[0-9]{4}$'), --шаблон, номер российский
  is_active		bool			not null,
  reader_name	varchar(50)		not null
);

create table library.book_rentals(
	rental_id				serial		not null,
	reader_id				int			not null references library.readers(reader_id)
										on delete restrict
										on update cascade,
	copy_id					int			not null references library.copy_of_the_book(copy_id)
										on delete restrict
										on update cascade,
	rental_type				varchar(20) check(rental_type in ('home','reading_room')),
	issue_date				date		not null default current_date, --дата выдачи = сегодняшней дате
	return_date_expected	date		not null check (return_date_expected >= issue_date), --дата возврата не может раньше даты выдачи
	return_date				date		null check (return_date >= issue_date),
	constraint book_rentals_unq primary key (rental_id, issue_date)
) partition by range (issue_date);

create table library.book_rentals_2024 
partition of library.book_rentals
for values from ('2024-01-01') to ('2025-01-01');

create table library.book_rentals_2025
partition of library.book_rentals
for values from ('2025-01-01') to ('2026-01-01');

create extension if not exists btree_gist;

create table library.reading_room_bookings(
	booking_id	serial		primary key,
	reader_id	int			not null references library.readers(reader_id)
							on delete restrict
							on update cascade,
	copy_id		int 		not null references library.copy_of_the_book(copy_id)
							on delete restrict
							on update cascade,
	time_from	timestamp	not null check (time_from >= current_timestamp),
	time_to		timestamp	not null check (time_to > time_from),
	status		varchar(15)	not null check (status in ('active', 'completed', 'cancelled')),
	constraint bookings_unq unique (reader_id, copy_id, time_from, time_to), -- альтернативный ключ: уникальность кто, что и период
	constraint prevent_overlapping_active_bookings -- ограничение на то, чтобы не было активных выдач одной копии экзмепляра в пересекающиеся периоды
		exclude using gist (
            copy_id with =,
            tsrange(time_from, time_to, '[]') with &&
        ) where (status = 'active')
);

create table library.fine_reason(
  reason_id   serial      	primary key,
  f_reason    varchar(30)   not null unique
);

create table library.fines(
	fine_id			serial	primary key,
	rental_id		int		not null,
	issue_date 		date 	not null,
	fine_sum	    money   not null check(fine_sum >= 0::money),
	reason_id       int     not null references library.fine_reason(reason_id)
                    		on delete restrict
                    		on update cascade,
	is_paid			bool	not null,
	payment_date    date   	not null check (payment_date <= current_date + 30), -- с текущей даты не более 30 дней
	foreign key (rental_id, issue_date) references library.book_rentals(rental_id, issue_date)
);

create index idx_bookings_cancelled_reader on library.reading_room_bookings(reader_id) 
where status = 'cancelled'; --отмененные брони читателя определенного, частый запрос библиотекаря

explain analyze
select * from reading_room_bookings 
where reader_id = 1 and status = 'cancelled';

create index idx_book_rentals_2024_not_returned on library.book_rentals_2024(reader_id) 
where return_date is null; --долги читателя по невозвращенным выдачам, частый запрос

create index idx_book_rentals_2025_not_returned on library.book_rentals_2025(reader_id) 
where return_date is null; --долги читателя по невозвращенным выдачам, частый запрос

explain analyze
select * from book_rentals
where reader_id = 1 and return_date is null;

create index idx_available_copy on library.copy_of_the_book(book_id)
where available = true; --доступная копия по айди книги, частый запрос

explain analyze
select copy_id from copy_of_the_book
where book_id = 1 and available = true;

create or replace function library.get_reader_stats(
    reader_id int,
    out current_rentals_count int,
    out overdue_rentals_count int,
    out active_bookings_count int,
    out total_violations_count int -- table переделать
)
language plpgsql strict stable as $$ --от одного reader_id бывают разные результаты, не может изменять бд
begin
	if reader_id <= 0 then
        raise exception 'некорректный id читателя';
    end if;
	
    select 
        count(*) filter (where return_date is null),
        count(*) filter (where return_date is null and return_date_expected < current_date)
    into current_rentals_count, overdue_rentals_count
    from library.book_rentals br
    where br.reader_id = get_reader_stats.reader_id;
    
    select 
        count(*) filter (where status = 'active'),
        count(*) filter (where status = 'cancelled')
    into active_bookings_count, total_violations_count
    from library.reading_room_bookings rrb
    where rrb.reader_id = get_reader_stats.reader_id;
     
  total_violations_count := total_violations_count + overdue_rentals_count;
    
    if current_rentals_count is null then
        current_rentals_count := 0;
    end if;
    
    if overdue_rentals_count is null then
        overdue_rentals_count := 0;
    end if;
    
    if active_bookings_count is null then
        active_bookings_count := 0;
    end if;
    
    if total_violations_count is null then
        total_violations_count := 0;
    end if;
end;
$$;

create or replace function library.get_reader_stats_table(
    reader_id int
)
returns table(
    current_rentals_count int,
    overdue_rentals_count int,
    active_bookings_count int,
    total_violations_count int
)
language plpgsql 
strict stable as $$
declare
    _current_rentals_count int;
    _overdue_rentals_count int;
    _active_bookings_count int;
    _total_violations_count int;
    _cancelled_bookings_count int;
begin
    if reader_id <= 0 then
        raise exception 'некорректный id читателя';
    end if;
  
    select 
        count(*) filter (where return_date is null),
        count(*) filter (where return_date is null and return_date_expected < current_date)
    into _current_rentals_count, _overdue_rentals_count
    from library.book_rentals br
    where br.reader_id = get_reader_stats.reader_id;

    select 
        count(*) filter (where status = 'active'),
        count(*) filter (where status = 'cancelled')
    into _active_bookings_count, _cancelled_bookings_count
    from library.reading_room_bookings rrb
    where rrb.reader_id = get_reader_stats.reader_id;
    
    _total_violations_count := _cancelled_bookings_count + _overdue_rentals_count;
    
    if _current_rentals_count is null then
        _current_rentals_count := 0;
    end if;
    
    if _overdue_rentals_count is null then
        _overdue_rentals_count := 0;
    end if;
    
    if _active_bookings_count is null then
        _active_bookings_count := 0;
    end if;
    
    if _total_violations_count is null then
        _total_violations_count := 0;
    end if;
    
    return query
    select 
        _current_rentals_count,
        _overdue_rentals_count,
        _active_bookings_count,
        _total_violations_count;
end;
$$;

create or replace function library.check_book_availability_before_rent()
returns trigger
language plpgsql
as $$
declare
    check_book_id int;
    check_available_copies int;
    check_current_rentals int;
	check_is_copy_available bool;
    check_max_books constant int := 5;
	_stack text;
begin
    select cotb.book_id, books.available_copies, cotb.available
	    into check_book_id, check_available_copies, check_is_copy_available
	    from library.copy_of_the_book as cotb
	    join library.books as books
		on cotb.book_id = books.book_id
	    where cotb.copy_id = new.copy_id
	for update of cotb, books nowait;

    if check_book_id is null then
		raise exception 'данного экземпляра не существует';
	end if;

	if not check_is_copy_available then
        raise exception 'данный экземпляр уже выдан';
    end if;

    if check_available_copies <= 0 then
        raise exception 'нет доступных копий книги';
    end if;
    
select count(*) into check_current_rentals
	from library.book_rentals
	where reader_id = new.reader_id and return_date is null;
    
    if check_current_rentals >= check_max_books then
        raise exception 'у читателя больше 5 книг на руках';
    end if;
    
	update library.books 
	set available_copies = available_copies - 1 
	where book_id = check_book_id;
	    
	update library.copy_of_the_book 
	set available = false 
	where copy_id = new.copy_id;

	return new;

exception
    when lock_not_available then
        raise exception 'книга сейчас выдается другим библиотекарем';
	when others then
		get stacked diagnostics
			_stack = pg_exception_context;
		raise e'[%]: % \n %',
			sqlstate, sqlerrm, _stack;
end;
$$;

create trigger trg_check_book_availability_before_rent
before insert on library.book_rentals  
for each row execute function library.check_book_availability_before_rent();

begin;
	set transaction isolation level repeatable read; 
    select * from library.copy_of_the_book
   	where copy_id = 101 and available = true
    for update nowait;  --блокируем

    -- если ничего не вывелось, то делаем откат rollback
    
    insert into library.book_rentals (reader_id, copy_id, rental_type, issue_date, return_date_expected)
    values (1, 101, 'home', current_date, current_date + 14);
    
    update library.copy_of_the_book set available = false where copy_id = 101;
    
    update library.books as books set available_copies = available_copies - 1
    from library.copy_of_the_book cotb
    where cotb.copy_id = 101 and books.book_id = cotb.book_id;
    
commit;

-- Но как будто лучше:
begin;
set transaction isolation level repeatable read;
	do $$ 
		begin
		    perform 1 from library.copy_of_the_book
		   	where copy_id = 101 and available = true
		    for update nowait;  --блокируем
		
		    if not found then 
				raise exception 'Книга уже выдана';
			end if;
		    
		    insert into library.book_rentals (reader_id, copy_id, rental_type, issue_date, return_date_expected)
		    values (1, 101, 'home', current_date, current_date + 14);
		    
		    update library.copy_of_the_book set available = false where copy_id = 101;
		    
		    update library.books as books set available_copies = available_copies - 1
		    from library.copy_of_the_book cotb
		    where cotb.copy_id = 101 and books.book_id = cotb.book_id;

			exception
			    when lock_not_available then
			        raise exception 'конфликт: книгу уже выдаёт другой библиотекарь';
	
	end $$
	language plpgsql;
commit;

-- все операторы в транзакции видят один и тот же снимок данных - тот, что был создан на момент начала первого оператора в транзакции.
-- команда select for update nowait находит строку, основываясь на снимке, если к этому моменту уже были внесены изменения другой транзакцией, то выйдет ошибка
-- вторая транзакция сможет получить ошибку serialization_failure или lock_not_available по идее

explain (analyze, buffers)
select books.book_id, books.title, count(br.rental_id) as total_rentals
from library.books as books
join library.copy_of_the_book as cotb on books.book_id = cotb.book_id
join library.book_rentals as br on cotb.copy_id = br.copy_id
where br.issue_date >= current_date - interval '1 year'
group by books.book_id, books.title
order by total_rentals desc
limit 10;
--
--Limit  (cost=161.67..161.69 rows=10 width=130) (actual time=0.037..0.038 rows=0 loops=1)
--  ->  Sort  (cost=161.67..162.77 rows=440 width=130) (actual time=0.036..0.037 rows=0 loops=1)
--        Sort Key: (count(br.rental_id)) DESC
--        Sort Method: quicksort  Memory: 25kB
--        ->  HashAggregate  (cost=147.76..152.16 rows=440 width=130) (actual time=0.023..0.024 rows=0 loops=1)
--              Group Key: books.book_id
--              Batches: 1  Memory Usage: 37kB
--              ->  Hash Join  (cost=79.40..144.19 rows=714 width=126) (actual time=0.019..0.020 rows=0 loops=1)
--                    Hash Cond: (cotb.book_id = books.book_id)
--                    ->  Hash Join  (cost=59.50..122.39 rows=714 width=8) (never executed)
--                          Hash Cond: (br.copy_id = cotb.copy_id)
--                          ->  Append  (cost=0.00..61.02 rows=714 width=8) (never executed)
--                                ->  Seq Scan on book_rentals_2024 br_1  (cost=0.00..28.73 rows=357 width=8) (never executed)
--                                      Filter: (issue_date >= (CURRENT_DATE - '1 year'::interval))
--                                ->  Seq Scan on book_rentals_2025 br_2  (cost=0.00..28.73 rows=357 width=8) (never executed)
--                                      Filter: (issue_date >= (CURRENT_DATE - '1 year'::interval))
--                          ->  Hash  (cost=32.00..32.00 rows=2200 width=8) (never executed)
--                                ->  Seq Scan on copy_of_the_book cotb  (cost=0.00..32.00 rows=2200 width=8) (never executed)
--                    ->  Hash  (cost=14.40..14.40 rows=440 width=122) (actual time=0.006..0.006 rows=0 loops=1)
--                          Buckets: 1024  Batches: 1  Memory Usage: 8kB
--                          ->  Seq Scan on books  (cost=0.00..14.40 rows=440 width=122) (actual time=0.006..0.006 rows=0 loops=1)
--Planning:
--  Buffers: shared hit=11
--Planning Time: 0.488 ms
--Execution Time: 0.113 ms

create index if not exists idx_book_rentals_issue_date 
on library.book_rentals (issue_date);

create index if not exists idx_copy_of_the_book_copy_id 
on library.copy_of_the_book (copy_id);

create index if not exists idx_book_rentals_copy_id 
on library.book_rentals (copy_id);


--Limit  (cost=150.56..150.59 rows=10 width=130) (actual time=0.019..0.020 rows=0 loops=1)
--  ->  Sort  (cost=150.56..151.66 rows=440 width=130) (actual time=0.018..0.019 rows=0 loops=1)
--        Sort Key: (count(br.rental_id)) DESC
--        Sort Method: quicksort  Memory: 25kB
--        ->  HashAggregate  (cost=136.65..141.05 rows=440 width=130) (actual time=0.012..0.013 rows=0 loops=1)
--              Group Key: books.book_id
--              Batches: 1  Memory Usage: 37kB
--              ->  Hash Join  (cost=86.32..133.08 rows=714 width=126) (actual time=0.009..0.010 rows=0 loops=1)
--                    Hash Cond: (cotb.book_id = books.book_id)
--                    ->  Hash Join  (cost=66.42..111.29 rows=714 width=8) (never executed)
--                          Hash Cond: (br.copy_id = cotb.copy_id)
--                          ->  Append  (cost=6.92..49.91 rows=714 width=8) (never executed)
--                                ->  Bitmap Heap Scan on book_rentals_2024 br_1  (cost=6.92..23.17 rows=357 width=8) (never executed)
--                                      Recheck Cond: (issue_date >= (CURRENT_DATE - '1 year'::interval))
--                                      ->  Bitmap Index Scan on book_rentals_2024_issue_date_idx  (cost=0.00..6.83 rows=357 width=0) (never executed)
--                                            Index Cond: (issue_date >= (CURRENT_DATE - '1 year'::interval))
--                                ->  Bitmap Heap Scan on book_rentals_2025 br_2  (cost=6.92..23.17 rows=357 width=8) (never executed)
--                                      Recheck Cond: (issue_date >= (CURRENT_DATE - '1 year'::interval))
--                                      ->  Bitmap Index Scan on book_rentals_2025_issue_date_idx  (cost=0.00..6.83 rows=357 width=0) (never executed)
--                                            Index Cond: (issue_date >= (CURRENT_DATE - '1 year'::interval))
--                          ->  Hash  (cost=32.00..32.00 rows=2200 width=8) (never executed)
--                                ->  Seq Scan on copy_of_the_book cotb  (cost=0.00..32.00 rows=2200 width=8) (never executed)
--                    ->  Hash  (cost=14.40..14.40 rows=440 width=122) (actual time=0.004..0.005 rows=0 loops=1)
--                          Buckets: 1024  Batches: 1  Memory Usage: 8kB
--                          ->  Seq Scan on books  (cost=0.00..14.40 rows=440 width=122) (actual time=0.004..0.004 rows=0 loops=1)
--Planning:
--  Buffers: shared hit=17
--Planning Time: 0.559 ms
--Execution Time: 0.097 ms


-- Проанализируйте эффективность секционирования таблицы book_rentals и предложите возможные улучшения структуры секционирования
-- В запросе затрагивается два года, поэтому анализируются полностью обе таблицы. Но нам не нужно столько. Можно сделать секционирование в каждом годе, например на четверти
-- Получим вложенное секционирование и нужно будет меньше данных обрабатывать

drop table if exists library.book_rentals_2025 cascade;

create table library.book_rentals_2025 partition of library.book_rentals
for values from ('2025-01-01') to ('2026-01-01')
partition by range (issue_date); 

create table library.book_rentals_2025_q1 
partition of library.book_rentals_2025
for values from ('2025-01-01') to ('2025-04-01');

create table library.book_rentals_2025_q2 
partition of library.book_rentals_2025
for values from ('2025-04-01') to ('2025-07-01');

create table library.book_rentals_2025_q3 
partition of library.book_rentals_2025
for values from ('2025-07-01') to ('2025-10-01');

create table library.book_rentals_2025_q4 
partition of library.book_rentals_2025
for values from ('2025-10-01') to ('2026-01-01');

drop table if exists library.book_rentals_2024 cascade;

create table library.book_rentals_2024 partition of library.book_rentals
for values from ('2024-01-01') to ('2025-01-01')
partition by range (issue_date); 

create table library.book_rentals_2024_q1 
partition of library.book_rentals_2024
for values from ('2024-01-01') to ('2024-04-01');

create table library.book_rentals_2024_q2 
partition of library.book_rentals_2024
for values from ('2024-04-01') to ('2024-07-01');

create table library.book_rentals_2024_q3 
partition of library.book_rentals_2024
for values from ('2024-07-01') to ('2024-10-01');

create table library.book_rentals_2024_q4 
partition of library.book_rentals_2024
for values from ('2024-10-01') to ('2025-01-01');

--Limit  (cost=322.31..322.34 rows=10 width=130) (actual time=0.054..0.056 rows=0 loops=1)
--  Buffers: shared hit=3
--  ->  Sort  (cost=322.31..323.41 rows=440 width=130) (actual time=0.052..0.054 rows=0 loops=1)
--        Sort Key: (count(br.rental_id)) DESC
--        Sort Method: quicksort  Memory: 25kB
--        Buffers: shared hit=3
--        ->  HashAggregate  (cost=308.41..312.81 rows=440 width=130) (actual time=0.027..0.029 rows=0 loops=1)
--              Group Key: books.book_id
--              Batches: 1  Memory Usage: 37kB
--              ->  Hash Join  (cost=86.32..294.13 rows=2856 width=126) (actual time=0.024..0.026 rows=0 loops=1)
--                    Hash Cond: (cotb.book_id = books.book_id)
--                    ->  Hash Join  (cost=66.42..266.66 rows=2856 width=8) (never executed)
--                          Hash Cond: (br.copy_id = cotb.copy_id)
--                          ->  Append  (cost=6.92..199.65 rows=2856 width=8) (never executed)
--                                Subplans Removed: 3
--                                ->  Bitmap Heap Scan on book_rentals_2024_q4 br_1  (cost=6.92..23.17 rows=357 width=8) (never executed)
--                                      Recheck Cond: (issue_date >= (CURRENT_DATE - '1 year'::interval))
--                                      ->  Bitmap Index Scan on book_rentals_2024_q4_issue_date_idx  (cost=0.00..6.83 rows=357 width=0) (never executed)
--                                            Index Cond: (issue_date >= (CURRENT_DATE - '1 year'::interval))
--                                ->  Bitmap Heap Scan on book_rentals_2025_q1 br_2  (cost=6.92..23.17 rows=357 width=8) (never executed)
--                                      Recheck Cond: (issue_date >= (CURRENT_DATE - '1 year'::interval))
--                                      ->  Bitmap Index Scan on book_rentals_2025_q1_issue_date_idx  (cost=0.00..6.83 rows=357 width=0) (never executed)
--                                            Index Cond: (issue_date >= (CURRENT_DATE - '1 year'::interval))
--                                ->  Bitmap Heap Scan on book_rentals_2025_q2 br_3  (cost=6.92..23.17 rows=357 width=8) (never executed)
--                                      Recheck Cond: (issue_date >= (CURRENT_DATE - '1 year'::interval))
--                                      ->  Bitmap Index Scan on book_rentals_2025_q2_issue_date_idx  (cost=0.00..6.83 rows=357 width=0) (never executed)
--                                            Index Cond: (issue_date >= (CURRENT_DATE - '1 year'::interval))
--                                ->  Bitmap Heap Scan on book_rentals_2025_q3 br_4  (cost=6.92..23.17 rows=357 width=8) (never executed)
--                                      Recheck Cond: (issue_date >= (CURRENT_DATE - '1 year'::interval))
--                                      ->  Bitmap Index Scan on book_rentals_2025_q3_issue_date_idx  (cost=0.00..6.83 rows=357 width=0) (never executed)
--                                            Index Cond: (issue_date >= (CURRENT_DATE - '1 year'::interval))
--                                ->  Bitmap Heap Scan on book_rentals_2025_q4 br_5  (cost=6.92..23.17 rows=357 width=8) (never executed)
--                                      Recheck Cond: (issue_date >= (CURRENT_DATE - '1 year'::interval))
--                                      ->  Bitmap Index Scan on book_rentals_2025_q4_issue_date_idx  (cost=0.00..6.83 rows=357 width=0) (never executed)
--                                            Index Cond: (issue_date >= (CURRENT_DATE - '1 year'::interval))
--                          ->  Hash  (cost=32.00..32.00 rows=2200 width=8) (never executed)
--                                ->  Seq Scan on copy_of_the_book cotb  (cost=0.00..32.00 rows=2200 width=8) (never executed)
--                    ->  Hash  (cost=14.40..14.40 rows=440 width=122) (actual time=0.007..0.007 rows=0 loops=1)
--                          Buckets: 1024  Batches: 1  Memory Usage: 8kB
--                          ->  Seq Scan on books  (cost=0.00..14.40 rows=440 width=122) (actual time=0.006..0.006 rows=0 loops=1)
--Planning:
--  Buffers: shared hit=728 read=24
--Planning Time: 2.900 ms
--Execution Time: 0.306 ms



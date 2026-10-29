package main

// Capstone 13.3: a news feed, two ways.
//
//	shortener drill feed   10,000 users; ordinary users have 100 followers, one celebrity has 10,000 (everyone).
//	                       fan-out on write: posting copies the post into every follower's feed table.
//	                       fan-out on read:  posting writes once; reading a feed merges the posts of everyone you follow.
//	                       Measures the time to post (ordinary user, celebrity) and to read one feed (p50 of 200 reads).

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

func feed(ctx context.Context, pool *pgxpool.Pool) map[string]any {
	pool.Exec(ctx, `DROP TABLE IF EXISTS follows, posts, timeline;
		CREATE TABLE follows (follower int, followee int, PRIMARY KEY (followee, follower));
		CREATE INDEX follows_follower ON follows (follower, followee);
		CREATE TABLE posts (id bigserial PRIMARY KEY, author int NOT NULL, at timestamptz NOT NULL DEFAULT now());
		CREATE INDEX posts_author ON posts (author, id DESC);
		CREATE TABLE timeline (owner int, post bigint, PRIMARY KEY (owner, post));
		-- user 1 is the celebrity: everyone follows them. Users 2..10000 each follow the next 100 users.
		INSERT INTO follows SELECT f, 1 FROM generate_series(2, 10000) f;
		INSERT INTO follows SELECT f, 2 + ((f + k) % 9999) FROM generate_series(2, 10000) f, generate_series(1, 100) k
			WHERE 2 + ((f + k) % 9999) <> f ON CONFLICT DO NOTHING;
		-- history: 20 earlier posts from every user, so feeds are not empty
		INSERT INTO posts (author, at) SELECT u, now() - (n || ' minutes')::interval FROM generate_series(1, 10000) u, generate_series(1, 20) n;
		ANALYZE`)
	timed := func(f func()) float64 { t := time.Now(); f(); return float64(time.Since(t).Microseconds()) / 1000 }
	post := func(author int, fanout bool) float64 {
		return timed(func() {
			var id int64
			pool.QueryRow(ctx, "INSERT INTO posts (author) VALUES ($1) RETURNING id", author).Scan(&id)
			if fanout {
				pool.Exec(ctx, "INSERT INTO timeline (owner, post) SELECT follower, $2 FROM follows WHERE followee = $1", author, id)
			}
		})
	}
	readMerged := func(user int) float64 {
		return timed(func() {
			rows, _ := pool.Query(ctx, `SELECT p.id FROM follows f JOIN LATERAL (SELECT id FROM posts WHERE author = f.followee
				ORDER BY id DESC LIMIT 20) p ON true WHERE f.follower = $1 ORDER BY p.id DESC LIMIT 20`, user)
			for rows.Next() {
			}
			rows.Close()
		})
	}
	readTimeline := func(user int) float64 {
		return timed(func() {
			rows, _ := pool.Query(ctx, "SELECT post FROM timeline WHERE owner = $1 ORDER BY post DESC LIMIT 20", user)
			for rows.Next() {
			}
			rows.Close()
		})
	}
	median := func(f func(int) float64) float64 {
		xs := make([]float64, 200)
		for i := range xs {
			xs[i] = f(2 + i*37%9999)
		}
		sortFloat(xs)
		return xs[100]
	}
	// fan-out on write: fill timelines for the last 20 posts of everyone first, so reads see a realistic table
	pool.Exec(ctx, `INSERT INTO timeline (owner, post) SELECT f.follower, p.id FROM follows f JOIN LATERAL
		(SELECT id FROM posts WHERE author = f.followee ORDER BY id DESC LIMIT 20) p ON true ON CONFLICT DO NOTHING`)
	// a freshly bulk-loaded table has no visibility map or statistics yet; a real timeline table would have both
	pool.Exec(ctx, "VACUUM ANALYZE timeline")
	return map[string]any{
		"users": 10000, "ordinary_followers": 100, "celebrity_followers": 9999,
		"write_ordinary_ms":    map[string]float64{"fanout_on_write": post(500, true), "fanout_on_read": post(501, false)},
		"write_celebrity_ms":   map[string]float64{"fanout_on_write": post(1, true), "fanout_on_read": post(1, false)},
		"read_feed_p50_ms":     map[string]float64{"fanout_on_write": median(readTimeline), "fanout_on_read": median(readMerged)},
		"timeline_rows_stored": countRows(ctx, pool, "timeline"),
	}
}

func countRows(ctx context.Context, pool *pgxpool.Pool, table string) int64 {
	var n int64
	pool.QueryRow(ctx, "SELECT count(*) FROM "+table).Scan(&n)
	return n
}

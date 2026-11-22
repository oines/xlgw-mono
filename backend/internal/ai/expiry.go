package ai

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5"
)

func (s *Service) expireConversations() {
	ticker := time.NewTicker(time.Minute)
	defer ticker.Stop()
	for {
		ctx, cancel := context.WithTimeout(s.ctx, 5*time.Second)
		err := s.expireDueConversations(ctx)
		cancel()
		if err != nil && s.ctx.Err() == nil {
			s.logger.Error("expire private AI conversations", "error", err)
		}
		select {
		case <-s.ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

func (s *Service) expireDueConversations(ctx context.Context) error {
	// Do not interrupt the closing Core session after Host status goes terminal.
	s.mu.Lock()
	defer s.mu.Unlock()
	active := make([]string, 0, len(s.active))
	for id := range s.active {
		active = append(active, id)
	}
	return s.store.mutate(ctx, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `SELECT `+conversationColumns+` FROM app.ai_conversations c
			WHERE c.expires_at<=now() AND NOT c.deleting AND c.id::text<>ALL($1::text[])
			AND NOT EXISTS (SELECT 1 FROM app.ai_runs r WHERE r.conversation_id=c.id AND r.status IN ('waiting','streaming'))
			ORDER BY c.expires_at,c.id LIMIT 20 FOR UPDATE OF c SKIP LOCKED`, active)
		if err != nil {
			return err
		}
		conversations, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (Conversation, error) {
			return scanConversation(row)
		})
		if err != nil {
			return err
		}
		for _, c := range conversations {
			// Recheck with a fresh snapshot after taking the lock used by admission.
			var running bool
			if err := tx.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM app.ai_runs
				WHERE conversation_id=$1 AND status IN ('waiting','streaming'))`, c.ID).Scan(&running); err != nil {
				return err
			}
			if running {
				continue
			}
			// A shared copy belongs to the care service and remains revocable.
			if _, err := tx.Exec(ctx, "UPDATE app.ai_shares SET conversation_id=NULL WHERE conversation_id=$1", c.ID); err != nil {
				return err
			}
			if err := deleteConversationData(ctx, tx, c); err != nil {
				return err
			}
		}
		return nil
	})
}

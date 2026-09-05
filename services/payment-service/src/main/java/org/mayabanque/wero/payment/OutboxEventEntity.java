package org.mayabanque.wero.payment;

import io.quarkus.hibernate.orm.panache.PanacheEntityBase;
import jakarta.persistence.*;
import java.time.Instant;

@Entity
@Table(name = "outbox_events")
public class OutboxEventEntity extends PanacheEntityBase {
    @Id @GeneratedValue(strategy = GenerationType.IDENTITY) public Long id;
    @Column(name = "event_id", nullable = false, unique = true, length = 64) public String eventId;
    @Column(name = "aggregate_type", nullable = false, length = 64) public String aggregateType;
    @Column(name = "aggregate_id", nullable = false, length = 128) public String aggregateId;
    @Column(name = "event_type", nullable = false, length = 64) public String eventType;
    @Column(name = "payload", nullable = false, columnDefinition = "text") public String payload;
    @Column(name = "correlation_id", length = 128) public String correlationId;
    @Column(name = "traceparent", length = 80) public String traceparent;
    @Column(name = "created_at", nullable = false) public Instant createdAt;
    @Column(name = "published_at") public Instant publishedAt;
    @Column(name = "publish_attempts", nullable = false) public int publishAttempts;
    @Column(name = "last_error", length = 500) public String lastError;
}

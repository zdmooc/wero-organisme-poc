package org.mayabanque.wero.payment;

import io.quarkus.hibernate.orm.panache.PanacheEntityBase;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.EnumType;
import jakarta.persistence.Enumerated;
import jakarta.persistence.Id;
import jakarta.persistence.Table;
import java.time.Instant;

@Entity
@Table(name = "payments")
public class PaymentEntity extends PanacheEntityBase {
    @Id
    @Column(name = "payment_id", nullable = false, length = 80)
    public String paymentId;

    @Column(name = "idempotency_key", nullable = false, unique = true, length = 120)
    public String idempotencyKey;

    @Column(name = "amount_cents", nullable = false)
    public long amountCents;

    @Column(nullable = false, length = 3)
    public String currency;

    @Column(name = "debtor_alias", nullable = false, length = 120)
    public String debtorAlias;

    @Column(name = "creditor_alias", nullable = false, length = 120)
    public String creditorAlias;

    @Column(name = "simulate_mode", length = 60)
    public String simulateMode;

    @Enumerated(EnumType.STRING)
    @Column(nullable = false, length = 20)
    public PaymentStatus status;

    @Column(name = "settlement_id", length = 120)
    public String settlementId;

    @Column(name = "last_error", length = 500)
    public String lastError;

    @Column(name = "created_at", nullable = false)
    public Instant createdAt;

    @Column(name = "updated_at", nullable = false)
    public Instant updatedAt;
}

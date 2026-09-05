package org.mayabanque.wero.payment;

import io.opentelemetry.api.trace.Span;
import io.quarkus.narayana.jta.QuarkusTransaction;
import io.quarkus.security.identity.SecurityIdentity;
import jakarta.annotation.security.RolesAllowed;
import jakarta.inject.Inject;
import jakarta.transaction.Transactional;
import jakarta.ws.rs.*;
import jakarta.ws.rs.core.MediaType;
import jakarta.ws.rs.core.Response;
import java.time.Instant;
import java.util.List;
import java.util.Objects;
import org.jboss.logging.Logger;

@Path("/payments")
@Consumes(MediaType.APPLICATION_JSON)
@Produces(MediaType.APPLICATION_JSON)
public class PaymentResource {

    private static final Logger LOG = Logger.getLogger(PaymentResource.class);

    @Inject PaymentRemoteGateway remoteGateway;
    @Inject OutboxService outbox;
    @Inject SecurityIdentity identity;
    @Inject PaymentMetrics metrics;

    @POST
    @Path("/single-immediate")
    @RolesAllowed("payment-create")
    public Response create(
            @HeaderParam("Idempotency-Key") String idempotencyKey,
            @HeaderParam("X-Consent-Id") String consentId,
            @HeaderParam("X-Correlation-Id") String correlationId,
            PaymentRequest request) {
        if (request == null || blank(request.paymentId()) || request.amountCents() <= 0 || blank(request.currency())) {
            return Response.status(Response.Status.BAD_REQUEST)
                    .entity(new ErrorResponse("INVALID_REQUEST", "paymentId, positive amountCents and currency are required")).build();
        }

        Span.current().setAttribute("wero.payment_id", request.paymentId());
        if (!blank(correlationId)) Span.current().setAttribute("wero.correlation_id", correlationId);
        LOG.infof("correlationId=%s paymentId=%s payment request", correlationId, request.paymentId());

        if (blank(idempotencyKey)) {
            return Response.status(Response.Status.BAD_REQUEST)
                    .entity(new ErrorResponse("IDEMPOTENCY_KEY_REQUIRED", "Idempotency-Key header is required")).build();
        }
        if (blank(consentId)) {
            return Response.status(Response.Status.BAD_REQUEST)
                    .entity(new ErrorResponse("CONSENT_REQUIRED", "X-Consent-Id header is required for a new payment")).build();
        }

        String subjectId = identity.getPrincipal().getName();

        // TX1: validate idempotency/consent and persist the local payment intent.
        // The transaction is fully committed before any outbound HTTP call occurs.
        PrepareResult prepared = QuarkusTransaction.requiringNew().call(
                () -> preparePayment(idempotencyKey, consentId, correlationId, subjectId, request));
        if (prepared.earlyResponse() != null) {
            return prepared.earlyResponse();
        }

        // Network I/O is deliberately outside any JTA transaction.
        DownstreamOutcome outcome;
        try {
            PaymentResponse downstream = remoteGateway.pay(correlationId, request);
            PaymentStatus status = switch (downstream.status()) {
                case "SETTLED" -> PaymentStatus.SETTLED;
                case "FAILED" -> PaymentStatus.FAILED;
                default -> PaymentStatus.PENDING;
            };
            outcome = new DownstreamOutcome(status, downstream.settlementId(), null);
        } catch (Exception e) {
            outcome = new DownstreamOutcome(
                    PaymentStatus.UNKNOWN,
                    null,
                    truncate(e.getClass().getSimpleName() + ": " + String.valueOf(e.getMessage()), 500));
        }

        DownstreamOutcome finalOutcome = outcome;
        // TX2: persist the result, ledger and outbox events atomically after the remote call.
        PaymentResponse result = QuarkusTransaction.requiringNew().call(
                () -> finalizePayment(request.paymentId(), correlationId, finalOutcome));

        PaymentStatus finalStatus = PaymentStatus.valueOf(result.status());
        metrics.paymentStatus(finalStatus);
        Span.current().setAttribute("wero.payment.status", result.status());
        LOG.infof("correlationId=%s paymentId=%s status=%s settlementId=%s",
                correlationId, result.paymentId(), result.status(), result.settlementId());

        int httpStatus = finalStatus == PaymentStatus.UNKNOWN || finalStatus == PaymentStatus.PENDING ? 202 : 200;
        return Response.status(httpStatus).entity(result).build();
    }

    private PrepareResult preparePayment(
            String idempotencyKey,
            String consentId,
            String correlationId,
            String subjectId,
            PaymentRequest request) {
        PaymentEntity existingByKey = PaymentEntity.find("idempotencyKey", idempotencyKey).firstResult();
        if (existingByKey != null) {
            if (!samePayload(existingByKey, request)) {
                return new PrepareResult(Response.status(Response.Status.CONFLICT)
                        .entity(new ErrorResponse("IDEMPOTENCY_CONFLICT", "The same Idempotency-Key was already used with a different payload"))
                        .build());
            }
            metrics.idempotentReplay();
            Span.current().setAttribute("wero.payment.status", existingByKey.status.name());
            return new PrepareResult(Response.ok(toResponse(existingByKey))
                    .header("X-Idempotent-Replay", "true")
                    .build());
        }

        PaymentEntity existingById = PaymentEntity.findById(request.paymentId());
        if (existingById != null) {
            return new PrepareResult(Response.status(Response.Status.CONFLICT)
                    .entity(new ErrorResponse("PAYMENT_ID_CONFLICT", "paymentId already exists with another idempotency key"))
                    .build());
        }

        ConsentEntity consent = ConsentEntity.findById(consentId);
        boolean sameSubject = consent != null && Objects.equals(consent.subjectId, subjectId);
        if (!sameSubject || !ConsentResource.isAuthorizedFor(consent, request)) {
            return new PrepareResult(Response.status(Response.Status.FORBIDDEN)
                    .entity(new ErrorResponse("CONSENT_NOT_AUTHORIZED", "Consent is missing, expired, not SCA-authorized, belongs to another subject, or does not match the payment"))
                    .build());
        }

        Instant now = Instant.now();
        PaymentEntity payment = new PaymentEntity();
        payment.paymentId = request.paymentId();
        payment.idempotencyKey = idempotencyKey;
        payment.consentId = consentId;
        payment.amountCents = request.amountCents();
        payment.currency = request.currency().toUpperCase();
        payment.debtorAlias = request.debtorAlias();
        payment.creditorAlias = request.creditorAlias();
        payment.simulateMode = request.simulateMode();
        payment.status = PaymentStatus.CREATED;
        payment.createdAt = now;
        payment.updatedAt = now;
        payment.persistAndFlush();
        outbox.enqueue(payment, "PAYMENT_CREATED", correlationId);

        payment.status = PaymentStatus.PROCESSING;
        payment.updatedAt = Instant.now();
        outbox.enqueue(payment, "PAYMENT_PROCESSING", correlationId);

        return new PrepareResult(null);
    }

    private PaymentResponse finalizePayment(String paymentId, String correlationId, DownstreamOutcome outcome) {
        PaymentEntity payment = PaymentEntity.findById(paymentId);
        if (payment == null) {
            throw new IllegalStateException("Payment disappeared before finalization: " + paymentId);
        }

        payment.status = outcome.status();
        payment.settlementId = outcome.settlementId();
        payment.lastError = outcome.lastError();
        payment.updatedAt = Instant.now();

        switch (payment.status) {
            case SETTLED -> {
                recordSettlementLedger(payment);
                outbox.enqueue(payment, "PAYMENT_SETTLED", correlationId);
            }
            case FAILED -> outbox.enqueue(payment, "PAYMENT_FAILED", correlationId);
            case PENDING -> outbox.enqueue(payment, "PAYMENT_PENDING", correlationId);
            case UNKNOWN -> outbox.enqueue(payment, "PAYMENT_UNKNOWN", correlationId);
            default -> { }
        }

        return toResponse(payment);
    }

    @GET
    @Path("/{paymentId}")
    @RolesAllowed("payment-read")
    @Transactional
    public Response get(@PathParam("paymentId") String paymentId) {
        PaymentEntity payment = PaymentEntity.findById(paymentId);
        if (payment == null) return Response.status(Response.Status.NOT_FOUND).entity(new ErrorResponse("PAYMENT_NOT_FOUND", paymentId)).build();
        Span.current().setAttribute("wero.payment_id", paymentId);
        return Response.ok(toDetails(payment)).build();
    }

    @GET
    @Path("/{paymentId}/ledger")
    @RolesAllowed("payment-read")
    @Transactional
    public Response ledger(@PathParam("paymentId") String paymentId) {
        PaymentEntity payment = PaymentEntity.findById(paymentId);
        if (payment == null) return Response.status(Response.Status.NOT_FOUND).entity(new ErrorResponse("PAYMENT_NOT_FOUND", paymentId)).build();
        List<LedgerEntryEntity> entries = LedgerEntryEntity.list("paymentId", paymentId);
        List<LedgerEntryView> result = entries.stream()
                .map(e -> new LedgerEntryView(e.id, e.paymentId, e.entryType, e.amountCents, e.currency, e.settlementId, e.createdAt)).toList();
        return Response.ok(result).build();
    }

    @POST
    @Path("/{paymentId}/reconcile")
    @RolesAllowed("payment-reconcile")
    public Response reconcile(@HeaderParam("X-Correlation-Id") String correlationId,
                              @PathParam("paymentId") String paymentId) {
        ReconcileState initial = QuarkusTransaction.requiringNew().call(() -> loadReconcileState(paymentId));
        if (initial == null) {
            return Response.status(Response.Status.NOT_FOUND).entity(new ErrorResponse("PAYMENT_NOT_FOUND", paymentId)).build();
        }

        Span.current().setAttribute("wero.payment_id", paymentId);
        if (!blank(correlationId)) Span.current().setAttribute("wero.correlation_id", correlationId);

        // Remote rail lookup is outside JTA, exactly like the payment orchestration call.
        SctInstStatusClient.RailStatus rail;
        try {
            rail = remoteGateway.railStatus(correlationId, paymentId);
        } catch (Exception e) {
            metrics.reconciliation("UNAVAILABLE");
            return Response.status(202)
                    .entity(new ReconciliationResponse(paymentId, initial.status(), "UNAVAILABLE", initial.status(), initial.settlementId()))
                    .build();
        }

        ReconciliationResponse result = QuarkusTransaction.requiringNew().call(
                () -> applyReconciliation(correlationId, paymentId, rail));
        metrics.reconciliation(result.afterStatus());
        Span.current().setAttribute("wero.payment.status", result.afterStatus());
        return Response.ok(result).build();
    }

    private ReconcileState loadReconcileState(String paymentId) {
        PaymentEntity payment = PaymentEntity.findById(paymentId);
        if (payment == null) return null;
        return new ReconcileState(payment.status.name(), payment.settlementId);
    }

    private ReconciliationResponse applyReconciliation(
            String correlationId,
            String paymentId,
            SctInstStatusClient.RailStatus rail) {
        PaymentEntity payment = PaymentEntity.findById(paymentId);
        if (payment == null) {
            throw new IllegalStateException("Payment disappeared before reconciliation: " + paymentId);
        }

        PaymentStatus before = payment.status;
        if ("SETTLED".equals(rail.status())) {
            payment.status = PaymentStatus.SETTLED;
            payment.settlementId = rail.settlementId();
            payment.lastError = null;
            payment.updatedAt = Instant.now();
            recordSettlementLedger(payment);
            if (before != PaymentStatus.SETTLED) {
                outbox.enqueue(payment, "PAYMENT_RECONCILED", correlationId);
                outbox.enqueue(payment, "PAYMENT_SETTLED", correlationId);
            }
        } else if ("FAILED".equals(rail.status())) {
            payment.status = PaymentStatus.FAILED;
            payment.lastError = null;
            payment.updatedAt = Instant.now();
            if (before != PaymentStatus.FAILED) {
                outbox.enqueue(payment, "PAYMENT_RECONCILED", correlationId);
                outbox.enqueue(payment, "PAYMENT_FAILED", correlationId);
            }
        }

        return new ReconciliationResponse(
                paymentId,
                before.name(),
                rail.status(),
                payment.status.name(),
                payment.settlementId);
    }

    private static void recordSettlementLedger(PaymentEntity payment) {
        long existing = LedgerEntryEntity.count("paymentId = ?1 and entryType = ?2", payment.paymentId, "SETTLEMENT");
        if (existing > 0) return;
        LedgerEntryEntity entry = new LedgerEntryEntity();
        entry.paymentId = payment.paymentId;
        entry.entryType = "SETTLEMENT";
        entry.amountCents = payment.amountCents;
        entry.currency = payment.currency;
        entry.settlementId = payment.settlementId;
        entry.createdAt = Instant.now();
        entry.persist();
    }

    private static boolean samePayload(PaymentEntity p, PaymentRequest r) {
        return Objects.equals(p.paymentId, r.paymentId()) && p.amountCents == r.amountCents()
                && Objects.equals(p.currency, r.currency() == null ? null : r.currency().toUpperCase())
                && Objects.equals(p.debtorAlias, r.debtorAlias()) && Objects.equals(p.creditorAlias, r.creditorAlias())
                && Objects.equals(p.simulateMode, r.simulateMode());
    }
    private static boolean blank(String value) { return value == null || value.isBlank(); }
    private static String truncate(String value, int max) { return value == null || value.length() <= max ? value : value.substring(0, max); }
    private static PaymentResponse toResponse(PaymentEntity p) { return new PaymentResponse(p.paymentId, p.status.name(), p.settlementId); }
    private static PaymentDetails toDetails(PaymentEntity p) {
        return new PaymentDetails(p.paymentId, p.idempotencyKey, p.consentId, p.amountCents, p.currency, p.debtorAlias,
                p.creditorAlias, p.status.name(), p.settlementId, p.lastError, p.createdAt, p.updatedAt);
    }

    private record PrepareResult(Response earlyResponse) {}
    private record DownstreamOutcome(PaymentStatus status, String settlementId, String lastError) {}
    private record ReconcileState(String status, String settlementId) {}

    public record PaymentRequest(String paymentId, long amountCents, String currency, String debtorAlias, String creditorAlias, String simulateMode) {}
    public record PaymentResponse(String paymentId, String status, String settlementId) {}
    public record PaymentDetails(String paymentId, String idempotencyKey, String consentId, long amountCents, String currency,
                                 String debtorAlias, String creditorAlias, String status, String settlementId, String lastError,
                                 Instant createdAt, Instant updatedAt) {}
    public record LedgerEntryView(Long id, String paymentId, String entryType, long amountCents, String currency, String settlementId, Instant createdAt) {}
    public record ReconciliationResponse(String paymentId, String beforeStatus, String railStatus, String afterStatus, String settlementId) {}
    public record ErrorResponse(String code, String message) {}
}

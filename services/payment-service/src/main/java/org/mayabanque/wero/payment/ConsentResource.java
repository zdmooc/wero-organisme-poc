package org.mayabanque.wero.payment;

import io.quarkus.narayana.jta.QuarkusTransaction;
import io.quarkus.security.identity.SecurityIdentity;
import jakarta.annotation.security.RolesAllowed;
import jakarta.inject.Inject;
import jakarta.transaction.Transactional;
import jakarta.ws.rs.Consumes;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.POST;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.PathParam;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.QueryParam;
import jakarta.ws.rs.core.MediaType;
import jakarta.ws.rs.core.Response;
import java.time.Instant;
import java.time.temporal.ChronoUnit;
import java.util.Objects;
import java.util.UUID;
import org.eclipse.microprofile.config.inject.ConfigProperty;

@Path("/consents")
@Consumes(MediaType.APPLICATION_JSON)
@Produces(MediaType.APPLICATION_JSON)
public class ConsentResource {

    @Inject
    SecurityIdentity identity;

    @ConfigProperty(name = "wero.sca.demo-code", defaultValue = "123456")
    String demoCode;

    @POST
    @RolesAllowed("consent-create")
    @Transactional
    public Response create(CreateConsentRequest request) {
        if (request == null || blank(request.paymentId()) || request.amountCents() <= 0
                || blank(request.currency()) || blank(request.creditorAlias())) {
            return Response.status(Response.Status.BAD_REQUEST)
                    .entity(new ErrorResponse("INVALID_CONSENT", "paymentId, positive amountCents, currency and creditorAlias are required"))
                    .build();
        }

        ConsentEntity existing = ConsentEntity.find("paymentId", request.paymentId()).firstResult();
        if (existing != null) {
            return Response.status(Response.Status.CONFLICT)
                    .entity(new ErrorResponse("CONSENT_PAYMENT_CONFLICT", "A consent already exists for this paymentId"))
                    .build();
        }

        Instant now = Instant.now();
        ConsentEntity consent = new ConsentEntity();
        consent.consentId = "CNS-" + UUID.randomUUID();
        consent.paymentId = request.paymentId();
        consent.amountCents = request.amountCents();
        consent.currency = request.currency().toUpperCase();
        consent.creditorAlias = request.creditorAlias();
        consent.subjectId = identity.getPrincipal().getName();
        consent.challengeId = "SCA-" + UUID.randomUUID();
        consent.status = ConsentStatus.PENDING_SCA;
        consent.scaAttempts = 0;
        consent.createdAt = now;
        consent.expiresAt = now.plus(5, ChronoUnit.MINUTES);
        consent.persist();

        return Response.status(Response.Status.CREATED).entity(toView(consent)).build();
    }

    @GET
    @Path("/{consentId}")
    @RolesAllowed({"consent-create", "consent-sca", "payment-read"})
    @Transactional
    public Response get(@PathParam("consentId") String consentId) {
        ConsentEntity consent = ConsentEntity.findById(consentId);
        if (consent == null) {
            return Response.status(Response.Status.NOT_FOUND)
                    .entity(new ErrorResponse("CONSENT_NOT_FOUND", consentId))
                    .build();
        }
        expireIfNeeded(consent);
        return Response.ok(toView(consent)).build();
    }

    @POST
    @Path("/{consentId}/sca")
    @RolesAllowed("consent-sca")
    public Response verifySca(@PathParam("consentId") String consentId, ScaRequest request) {
        // Keep the REST/security interceptor chain outside JTA. The complete SCA
        // read/update/commit happens synchronously inside one explicit transaction.
        return QuarkusTransaction.requiringNew().call(() -> verifyScaTx(consentId, request));
    }

    private Response verifyScaTx(String consentId, ScaRequest request) {
        ConsentEntity consent = ConsentEntity.findById(consentId);
        if (consent == null) {
            return Response.status(Response.Status.NOT_FOUND)
                    .entity(new ErrorResponse("CONSENT_NOT_FOUND", consentId))
                    .build();
        }
        expireIfNeeded(consent);
        if (consent.status == ConsentStatus.EXPIRED) {
            return Response.status(Response.Status.GONE).entity(toView(consent)).build();
        }
        if (consent.status == ConsentStatus.LOCKED || consent.status == ConsentStatus.REJECTED) {
            return Response.status(Response.Status.FORBIDDEN).entity(toView(consent)).build();
        }
        if (consent.status == ConsentStatus.AUTHORIZED) {
            return Response.ok(toView(consent)).build();
        }

        if (request == null || !Objects.equals(demoCode, request.code())) {
            consent.scaAttempts++;
            if (consent.scaAttempts >= 3) {
                consent.status = ConsentStatus.LOCKED;
            }
            return Response.status(Response.Status.FORBIDDEN).entity(toView(consent)).build();
        }

        consent.status = ConsentStatus.AUTHORIZED;
        consent.authorizedAt = Instant.now();
        return Response.ok(toView(consent)).build();
    }

    @GET
    @Path("/{consentId}/authorization")
    @RolesAllowed("payment-create")
    @Transactional
    public AuthorizationView authorization(
            @PathParam("consentId") String consentId,
            @QueryParam("paymentId") String paymentId,
            @QueryParam("amountCents") long amountCents,
            @QueryParam("currency") String currency,
            @QueryParam("creditorAlias") String creditorAlias) {
        ConsentEntity consent = ConsentEntity.findById(consentId);
        if (consent == null) {
            return new AuthorizationView(consentId, false, "NOT_FOUND", "Consent not found");
        }
        expireIfNeeded(consent);
        if (consent.status != ConsentStatus.AUTHORIZED) {
            return new AuthorizationView(consentId, false, consent.status.name(), "Consent is not authorized");
        }
        boolean samePayment = Objects.equals(consent.paymentId, paymentId)
                && consent.amountCents == amountCents
                && Objects.equals(consent.currency, currency == null ? null : currency.toUpperCase())
                && Objects.equals(consent.creditorAlias, creditorAlias);
        return new AuthorizationView(
                consentId,
                samePayment,
                consent.status.name(),
                samePayment ? "AUTHORIZED" : "Consent does not match payment payload");
    }

    static boolean isAuthorizedFor(ConsentEntity consent, PaymentResource.PaymentRequest request) {
        if (consent == null || consent.status != ConsentStatus.AUTHORIZED || consent.expiresAt.isBefore(Instant.now())) {
            return false;
        }
        return Objects.equals(consent.paymentId, request.paymentId())
                && consent.amountCents == request.amountCents()
                && Objects.equals(consent.currency, request.currency() == null ? null : request.currency().toUpperCase())
                && Objects.equals(consent.creditorAlias, request.creditorAlias());
    }

    private static void expireIfNeeded(ConsentEntity consent) {
        if (consent.status == ConsentStatus.PENDING_SCA && consent.expiresAt.isBefore(Instant.now())) {
            consent.status = ConsentStatus.EXPIRED;
        }
    }

    private static ConsentView toView(ConsentEntity c) {
        return new ConsentView(c.consentId, c.paymentId, c.amountCents, c.currency, c.creditorAlias,
                c.subjectId, c.challengeId, c.status.name(), c.scaAttempts, c.createdAt, c.expiresAt, c.authorizedAt);
    }

    private static boolean blank(String value) {
        return value == null || value.isBlank();
    }

    public record CreateConsentRequest(String paymentId, long amountCents, String currency, String creditorAlias) {}
    public record ScaRequest(String code) {}
    public record ConsentView(String consentId, String paymentId, long amountCents, String currency,
                              String creditorAlias, String subjectId, String challengeId, String status,
                              int scaAttempts, Instant createdAt, Instant expiresAt, Instant authorizedAt) {}
    public record AuthorizationView(String consentId, boolean authorized, String status, String reason) {}
    public record ErrorResponse(String code, String message) {}
}

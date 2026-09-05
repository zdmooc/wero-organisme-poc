package org.mayabanque.wero.consumer;

import io.opentelemetry.api.trace.Span;
import jakarta.inject.Inject;
import jakarta.ws.rs.*;
import jakarta.ws.rs.core.MediaType;
import org.eclipse.microprofile.rest.client.inject.RestClient;
import org.jboss.logging.Logger;

@Path("/consumer/payments")
@Consumes(MediaType.APPLICATION_JSON)
@Produces(MediaType.APPLICATION_JSON)
public class ConsumerPaymentResource {
    private static final Logger LOG = Logger.getLogger(ConsumerPaymentResource.class);
    @Inject @RestClient WeroClient wero;

    @POST
    public PaymentResponse pay(@HeaderParam("X-Correlation-Id") String correlationId, PaymentRequest request) {
        Span.current().setAttribute("wero.payment_id", request.paymentId());
        if (correlationId != null) Span.current().setAttribute("wero.correlation_id", correlationId);
        LOG.infof("correlationId=%s paymentId=%s consumer-psp forward", correlationId, request.paymentId());
        return wero.forward(correlationId, request);
    }

    public record PaymentRequest(String paymentId, long amountCents, String currency, String debtorAlias,
                                 String creditorAlias, String simulateMode) {}
    public record PaymentResponse(String paymentId, String status, String settlementId) {}
}
